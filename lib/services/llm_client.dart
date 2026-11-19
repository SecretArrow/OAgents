import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart' show TokenUsage;
import 'opencode_client.dart';

/// Connection settings for the opencode server — the SOLE AI backend in
/// OAgents. There is no `engine` field and no per-provider routing: every
/// turn is a streaming `POST {serverUrl}/chat/completions` handled by
/// [OpencodeClient].
class LlmConfig {
  const LlmConfig({
    required this.serverUrl,
    required this.authToken,
    required this.model,
    this.maxTokens,
  });

  /// Base URL of the opencode server, e.g. `http://192.168.1.10:4096`.
  final String serverUrl;

  /// Bearer token sent as `Authorization: Bearer <authToken>`. Empty when
  /// the server runs unauthenticated on the LAN.
  final String authToken;

  /// opencode model id (from `GET {serverUrl}/models`). Empty = let the
  /// server pick its configured default.
  final String model;

  /// Optional hard cap on generated tokens (null = server default). Most
  /// opencode frontends ignore it; kept for forward compatibility with
  /// Anthropic-shaped backends that require `max_tokens`.
  final int? maxTokens;
}

/// A tool call requested by the model (arguments still raw JSON string).
class ToolCallRequest {
  ToolCallRequest({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  final String id;
  final String name;
  final String argumentsJson;

  /// Parsed arguments; falls back to an empty map on malformed JSON.
  Map<String, dynamic> get args {
    try {
      final decoded = jsonDecode(argumentsJson.isEmpty ? '{}' : argumentsJson);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // fall through
    }
    return <String, dynamic>{};
  }
}

/// Thrown when [LlmClient.complete] is aborted through its `shouldAbort`
/// callback (the user pressed Stop). Carries whatever content was already
/// streamed so the caller can keep the partial answer.
class LlmAbortedException implements Exception {
  const LlmAbortedException(this.partialContent);

  final String partialContent;

  @override
  String toString() => 'LlmAbortedException';
}

/// One completed assistant turn: streamed text + any tool calls.
class AssistantTurn {
  AssistantTurn({
    required this.content,
    this.toolCalls = const <ToolCallRequest>[],
    this.usage,
  });

  final String content;
  final List<ToolCallRequest> toolCalls;

  /// Token usage reported by the server for this turn (null when the
  /// server does not report it or the stream was cut short).
  final TokenUsage? usage;

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

class LlmException implements Exception {
  LlmException(this.message, {this.statusCode});

  final String message;

  /// HTTP status code when the failure came from a server response —
  /// lets the auto-retry logic tell transient server errors (429/5xx,
  /// worth another attempt) from permanent ones (401/400).
  final int? statusCode;

  @override
  String toString() => message;
}

/// True when [error] is worth another automatic attempt (auto-retry):
/// transport failures (unreachable server, dropped stream, socket or
/// timeout errors) and transient HTTP responses (408/425/429 and all
/// 5xx). Authentication and bad-request errors are permanent — retrying
/// them would only burn the attempt budget. A user-initiated
/// [LlmAbortedException] (Stop) is never retried.
bool isRetryableLlmError(Object? error) => isRetryableOpencodeError(error);

int _callCounter = 0;
String newCallId() =>
    'call_${DateTime.now().millisecondsSinceEpoch}_${_callCounter++}';

/// Streaming chat client. In OAgents there is exactly one implementation:
/// it delegates to [OpencodeClient], which speaks the opencode HTTP/SSE
/// contract documented in `opencode_client.dart`.
///
/// The class keeps its historical name (`LlmClient`) and `complete()`
/// signature so every existing caller (chat controller, agent composer,
/// agent polisher, subagents runner, cron dispatcher) is unchanged — only
/// the wire transport underneath was swapped from multi-provider
/// OpenAI/Anthropic/Responses routing to a single opencode endpoint.
class LlmClient {
  LlmClient({http.Client? httpClient, OpencodeClient? opencode})
    : _opencode = opencode ?? OpencodeClient(client: httpClient);

  final OpencodeClient _opencode;

  /// Live streaming requests keyed by the caller's [cancelKey] (the agent
  /// loop passes its per-run object). [forceCancel] looks a run up here
  /// and hard-closes its HTTP client, which aborts even a STALLED stream
  /// that emits no deltas (the `shouldAbort` poll only runs between
  /// chunks — a silent connection would otherwise pin the run forever).
  static final Map<Object, http.Client> _liveStreams = <Object, http.Client>{};

  /// Registers [client] as the live request for [key]. Called by
  /// [OpencodeClient.chatStream] so [forceCancel] can tear it down
  /// mid-flight. Shared static so the cancel path is identical for every
  /// LlmClient instance (agent loop, subagents, cron).
  static void registerLiveStream(Object key, http.Client client) {
    _liveStreams[key] = client;
  }

  /// Removes [client] from [key]'s registry — only when it is still the
  /// registered one, so a retried request under the same key is never
  /// clobbered by the previous attempt's cleanup.
  static void unregisterLiveStream(Object key, http.Client client) {
    if (identical(_liveStreams[key], client)) _liveStreams.remove(key);
  }

  /// Force-stops the in-flight request(s) registered under [cancelKey]:
  /// the client is closed forcefully so the pending socket read errors out
  /// immediately. Returns true when a live request was found and killed.
  /// Safe to call at any time; no-op when nothing is registered (run
  /// already between requests, finished, or a test double).
  static bool forceCancel(Object cancelKey) {
    final http.Client? client = _liveStreams.remove(cancelKey);
    if (client == null) return false;
    try {
      client.close();
    } catch (_) {
      // Best-effort: a broken transport is exactly the state we want.
    }
    return true;
  }

  /// Sends a chat completion request to the opencode server and streams
  /// the assistant turn.
  ///
  /// [onDelta] receives incremental content tokens while streaming. Tool
  /// call deltas are accumulated internally and returned with the turn.
  /// [shouldAbort] is polled while streaming; when it returns true the
  /// connection is torn down immediately and [LlmAbortedException] is
  /// thrown with the partial content — Stop must feel instant.
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) {
    if (shouldAbort?.call() ?? false) {
      throw const LlmAbortedException('');
    }
    return _opencode.chatStream(
      config: config,
      messages: messages,
      tools: tools,
      onDelta: onDelta,
      shouldAbort: shouldAbort,
      cancelKey: cancelKey,
    );
  }
}
