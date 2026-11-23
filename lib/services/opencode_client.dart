import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, SocketException;
import 'dart:isolate' show Isolate;

import 'package:http/http.dart' as http;

import '../models/models.dart' show TokenUsage;
import 'llm_client.dart';

/// OAgents ↔ opencode server HTTP contract.
///
/// OAgents talks to **one** AI backend: an opencode server. opencode's own
/// native transport is a Bun/TypeScript SDK; to keep OAgents a pure Flutter
/// citizen (no embedded JS runtime for the chat path) we define a small,
/// stable HTTP contract any opencode deployment can expose — either by
/// running opencode behind the companion adapter
/// (`tool/opencode-adapter.mjs`, ~80 lines of Node that wraps
/// `opencode.chat` into the endpoints below) or by pointing OAgents at any
/// OpenAI-compatible streaming frontend already fronting opencode.
///
/// The contract is intentionally OpenAI-shaped so the wire format is
/// well-understood, mockable in 30 lines, and identical to what the
/// project's previous LLM transport already spoke — only the *provider
/// multiplexing* is gone. There is exactly one server URL, one token, one
/// model picker fed by `GET /models`.
///
/// Endpoints (base = [LlmConfig.serverUrl], no trailing slash):
///
///  * `GET  /health`           → `204` (connection probe, no body).
///  * `GET  /models`           → `{"data":[{"id":String,"name":String}]}`.
///  * `POST /chat/completions` → SSE stream (`Content-Type: text/event-stream`).
///      Request body:
///        ```
///        {
///          "model":  "<opencodeModel or empty>",
///          "messages":[{"role":"system|user|assistant|tool","content":...}],
///          "stream": true,
///          "tools":   <optional, OpenAI tool schema>
///        }
///        ```
///      Auth: `Authorization: Bearer <authToken>` when non-empty.
///      SSE lines (`data: <json>\n\n`):
///        * `{"choices":[{"delta":{"content":"..."}}]}`            — text chunk
///        * `{"choices":[{"delta":{"tool_calls":[{...}]}}]}`        — tool call
///        * `{"choices":[],"usage":{"prompt_tokens":N,"completion_tokens":M}}`
///        * `data: [DONE]`                                          — stream end
///      Non-200 responses carry an error body surfaced verbatim (truncated
///      to 600 chars) so auth/config mistakes are diagnosable.
class OpencodeModel {
  const OpencodeModel({required this.id, this.name = ''});

  final String id;
  final String name;

  factory OpencodeModel.fromJson(Map<String, dynamic> json) => OpencodeModel(
    id: (json['id'] ?? json['name'] ?? '').toString(),
    name: (json['name'] ?? json['id'] ?? '').toString(),
  );

  @override
  String toString() => name.isEmpty ? id : '$id ($name)';
}

/// One provider credential stored by the opencode server
/// (`GET/POST /api/credential`). Only the non-secret metadata is kept —
/// the API key itself is never parsed out of `value` and never held in
/// app memory beyond the moment it is POSTed.
class OpencodeCredential {
  const OpencodeCredential({
    required this.id,
    required this.integrationID,
    this.label = 'default',
    this.active = false,
  });

  final String id;
  final String integrationID;
  final String label;
  final bool active;

  /// Defensive parse of a `data` row: unknown shapes degrade to empty
  /// strings instead of throwing (same posture as [OpencodeModel.fromJson]
  /// over the wire formats the embedded server actually returns).
  factory OpencodeCredential.fromJson(Map<String, dynamic> json) =>
      OpencodeCredential(
        id: (json['id'] ?? '').toString(),
        integrationID: (json['integrationID'] ?? '').toString(),
        label: (json['label'] ?? 'default').toString(),
        active: json['active'] is bool ? json['active'] as bool : false,
      );

  @override
  String toString() =>
      'OpencodeCredential($integrationID, label=$label, active=$active)';
}

/// Thrown when the opencode server cannot be reached or returns a
/// non-2xx response that is not a normal SSE error event.
class OpencodeHttpException implements Exception {
  const OpencodeHttpException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? message : 'HTTP $statusCode: $message';
}

/// HTTP client for an opencode server. Stateless across calls; the caller
/// owns auth/url resolution (settings-driven) and may inject an
/// [http.Client] for tests. Every method is a thin wrapper so behaviour
/// stays auditable and the mock server in `test/support/` is the only other
/// place this contract is implemented.
class OpencodeClient {
  OpencodeClient({http.Client? client}) : _injected = client;

  final http.Client? _injected;

  http.Client _client() => _injected ?? http.Client();

  /// Returns true when `GET {server}/health` responds 2xx within
  /// [timeout]. Never throws — a connection failure is a normal "server
  /// not up yet" state for the Settings screen.
  Future<bool> ping({
    required String serverUrl,
    String authToken = '',
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final Uri? uri = Uri.tryParse('${serverUrl.trim()}/health');
    if (uri == null) return false;
    final http.Client client = _client();
    final bool owns = _injected == null;
    try {
      final http.Response res = await client
          .get(uri, headers: _headers(authToken))
          .timeout(timeout);
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      if (owns) client.close();
    }
  }

  /// Lists models advertised by the opencode server. Returns an empty list
  /// on any failure (the picker falls back to manual entry).
  Future<List<OpencodeModel>> listModels({
    required String serverUrl,
    String authToken = '',
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final Uri? uri = Uri.tryParse('${serverUrl.trim()}/models');
    if (uri == null) return const <OpencodeModel>[];
    final http.Client client = _client();
    final bool owns = _injected == null;
    try {
      final http.Response res = await client
          .get(uri, headers: _headers(authToken))
          .timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return const <OpencodeModel>[];
      }
      final dynamic decoded = jsonDecode(res.body);
      final List<dynamic> data = (decoded is Map && decoded['data'] is List)
          ? decoded['data'] as List<dynamic>
          : (decoded is List ? decoded : const <dynamic>[]);
      return data
          .whereType<Map<String, dynamic>>()
          .map(OpencodeModel.fromJson)
          .where((m) => m.id.isNotEmpty)
          .toList();
    } catch (_) {
      return const <OpencodeModel>[];
    } finally {
      if (owns) client.close();
    }
  }

  /// Lists provider credentials stored by the opencode server
  /// (`GET /api/credential` → `{"data":[Credential,...]}`). The embedded
  /// compat adapter on [serverUrl] proxies the `/api/*` surface verbatim,
  /// so this speaks opencode's own protocol directly. Never throws — a
  /// failure degrades to an empty list (the credentials screen keeps its
  /// own retry surface; [listModels] behaves the same way).
  Future<List<OpencodeCredential>> listCredentials({
    required String serverUrl,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final Uri? uri = Uri.tryParse('${serverUrl.trim()}/api/credential');
    if (uri == null) return const <OpencodeCredential>[];
    final http.Client client = _client();
    final bool owns = _injected == null;
    try {
      final http.Response res = await client
          .get(uri, headers: const <String, String>{})
          .timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return const <OpencodeCredential>[];
      }
      final dynamic decoded = jsonDecode(res.body);
      final List<dynamic> data = (decoded is Map && decoded['data'] is List)
          ? decoded['data'] as List<dynamic>
          : (decoded is List ? decoded : const <dynamic>[]);
      return data
          .whereType<Map<String, dynamic>>()
          .map(OpencodeCredential.fromJson)
          .where((c) => c.id.isNotEmpty)
          .toList();
    } catch (_) {
      return const <OpencodeCredential>[];
    } finally {
      if (owns) client.close();
    }
  }

  /// Stores one provider API key on the opencode server
  /// (`POST /api/credential`). The key travels inside the `value` union
  /// (`{"type":"key","key":...}`) and is only ever sent over the loopback
  /// adapter — it never touches app storage. Returns the created
  /// [OpencodeCredential] (server-generated `cred_...` id included) so the
  /// UI can refresh the list without a re-fetch.
  ///
  /// [activate] mirrors the server's exclusive-activation rule: with
  /// `true` (the default) the new key becomes THE active credential for
  /// [integrationID] and every other key of that provider flips to
  /// inactive.
  Future<OpencodeCredential> createCredential({
    required String serverUrl,
    required String integrationID,
    required String apiKey,
    String label = 'default',
    bool activate = true,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final String base = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final Uri uri = Uri.parse('$base/api/credential');
    final Map<String, dynamic> body = <String, dynamic>{
      'integrationID': integrationID,
      'value': <String, dynamic>{'type': 'key', 'key': apiKey},
      'label': label,
      'activate': activate,
    };
    final http.Client client = _client();
    final bool owns = _injected == null;
    try {
      final http.Response res = await client
          .post(
            uri,
            headers: const <String, String>{
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final String provider = integrationID.isEmpty ? 'key' : integrationID;
        throw OpencodeHttpException(
          'Could not save $provider key: ${_truncate(res.body, 300)}',
          statusCode: res.statusCode,
        );
      }
      final dynamic decoded = jsonDecode(res.body);
      final dynamic data = decoded is Map ? decoded['data'] : null;
      if (data is Map<String, dynamic>) {
        return OpencodeCredential.fromJson(data);
      }
      // 2xx without a parseable `data` envelope — the server accepted the
      // key, so report it with the values we sent rather than failing.
      return OpencodeCredential(
        id: '',
        integrationID: integrationID,
        label: label,
        active: activate,
      );
    } catch (e) {
      if (e is OpencodeHttpException) rethrow;
      throw OpencodeHttpException(
        'Could not reach opencode server to save key: $e',
      );
    } finally {
      if (owns) client.close();
    }
  }

  /// Removes a credential (`DELETE /api/credential/{id}` → 204). Safe to
  /// call for an id the server already forgot — the endpoint answers 204
  /// either way (idempotent no-op style).
  Future<void> deleteCredential({
    required String serverUrl,
    required String id,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final String base = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final Uri uri = Uri.parse('$base/api/credential/$id');
    final http.Client client = _client();
    final bool owns = _injected == null;
    try {
      final http.Response res = await client
          .delete(uri, headers: const <String, String>{})
          .timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw OpencodeHttpException(
          'Could not delete key: ${_truncate(res.body, 300)}',
          statusCode: res.statusCode,
        );
      }
    } catch (e) {
      if (e is OpencodeHttpException) rethrow;
      throw OpencodeHttpException(
        'Could not reach opencode server to delete key: $e',
      );
    } finally {
      if (owns) client.close();
    }
  }

  /// Makes a credential THE active one for its provider
  /// (`POST /api/credential/{id}/activate` → 204). Activation is exclusive
  /// per `integrationID` on the server side: this call also flips every
  /// other key of the same provider to inactive.
  Future<void> activateCredential({
    required String serverUrl,
    required String id,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final String base = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final Uri uri = Uri.parse('$base/api/credential/$id/activate');
    final http.Client client = _client();
    final bool owns = _injected == null;
    try {
      final http.Response res = await client
          .post(uri, headers: const <String, String>{})
          .timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw OpencodeHttpException(
          'Could not activate key: ${_truncate(res.body, 300)}',
          statusCode: res.statusCode,
        );
      }
    } catch (e) {
      if (e is OpencodeHttpException) rethrow;
      throw OpencodeHttpException(
        'Could not reach opencode server to activate key: $e',
      );
    } finally {
      if (owns) client.close();
    }
  }

  /// Streams one chat completion turn from the opencode server. Returns the
  /// final [AssistantTurn] (text + accumulated tool calls + usage).
  ///
  /// [cancelKey] registers the per-call HTTP client with [LlmClient]'s live
  /// stream registry so [LlmClient.forceCancel] can tear it down mid-flight
  /// even when the stream has gone silent (the `shouldAbort` poll only runs
  /// between chunks).
  Future<AssistantTurn> chatStream({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    final String base = config.serverUrl.replaceAll(RegExp(r'/+$'), '');
    final Uri uri = Uri.parse('$base/chat/completions');
    final Map<String, dynamic> body = <String, dynamic>{
      if (config.model.isNotEmpty) 'model': config.model,
      'messages': messages,
      'stream': true,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
      if (tools != null && tools.isNotEmpty) 'tool_choice': 'auto',
      // Ask the server to include a final usage chunk. Servers that do not
      // understand the field simply ignore it; the stream still completes.
      'stream_options': <String, dynamic>{'include_usage': true},
    };

    final http.Client callClient = _client();
    final bool owns = _injected == null;
    if (cancelKey != null) {
      LlmClient.registerLiveStream(cancelKey, callClient);
    }
    try {
      final http.Request request = http.Request('POST', uri)
        ..headers['Authorization'] = 'Bearer ${config.authToken}'
        ..headers['Content-Type'] = 'application/json'
        ..headers['Accept'] = 'text/event-stream'
        ..headers['X-Title'] = 'OAgents'
        // Encode off the UI isolate — a long conversation with base64
        // attachments can be multiple MB and a main-thread jsonEncode
        // stalls every frame (same reason ChatStore.save isolates).
        ..body = await Isolate.run(() => jsonEncode(body));
      final http.StreamedResponse response;
      try {
        response = await callClient.send(request);
      } catch (e) {
        throw LlmException('Could not connect to opencode server: $e');
      }

      if (response.statusCode == 400) {
        // Some opencode frontends reject `stream_options` — one quiet retry
        // without it keeps the chat working (usage simply stays null).
        final String errorBody = await response.stream.bytesToString();
        if (errorBody.contains('stream_options')) {
          final Map<String, dynamic> retryBody = Map<String, dynamic>.of(body)
            ..remove('stream_options');
          final http.Request retry = http.Request('POST', uri)
            ..headers['Authorization'] = 'Bearer ${config.authToken}'
            ..headers['Content-Type'] = 'application/json'
            ..headers['Accept'] = 'text/event-stream'
            ..body = await Isolate.run(() => jsonEncode(retryBody));
          try {
            final http.StreamedResponse retryRes = await callClient.send(retry);
            if (retryRes.statusCode == 200) {
              return _consume(retryRes, onDelta, shouldAbort);
            }
          } catch (_) {
            // Fall through to the normal error path below.
          }
        }
        throw LlmException(
          'HTTP 400: ${_truncate(errorBody, 300)}',
          statusCode: 400,
        );
      }
      if (response.statusCode != 200) {
        final String raw = await response.stream.bytesToString();
        throw LlmException(
          'HTTP ${response.statusCode}: ${_truncate(raw, 600)}',
          statusCode: response.statusCode,
        );
      }
      return _consume(response, onDelta, shouldAbort);
    } finally {
      if (cancelKey != null) {
        LlmClient.unregisterLiveStream(cancelKey, callClient);
      }
      if (owns) {
        try {
          callClient.close();
        } catch (_) {
          // Never let transport cleanup mask the actual result.
        }
      }
    }
  }

  Map<String, String> _headers(String authToken) {
    if (authToken.trim().isEmpty) return const <String, String>{};
    return <String, String>{'Authorization': 'Bearer ${authToken.trim()}'};
  }

  Future<AssistantTurn> _consume(
    http.StreamedResponse response,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
  ) async {
    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    if (!contentType.contains('text/event-stream')) {
      // Server ignored `stream: true` — parse a plain JSON response.
      if (shouldAbort?.call() ?? false) {
        throw const LlmAbortedException('');
      }
      final String raw = await response.stream.bytesToString();
      return _parseNonStreaming(raw);
    }
    try {
      return await _parseSse(response.stream, onDelta, shouldAbort);
    } on LlmAbortedException {
      rethrow;
    } on LlmException {
      rethrow;
    } catch (e) {
      throw LlmException('Connection lost while streaming: $e');
    }
  }

  AssistantTurn _parseNonStreaming(String raw) {
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final choices = decoded['choices'];
        if (choices is List && choices.isNotEmpty) {
          final message = choices.first['message'];
          if (message is Map<String, dynamic>) {
            return AssistantTurn(
              content: message['content']?.toString() ?? '',
              toolCalls: _parseFullToolCalls(message['tool_calls']),
              usage: TokenUsage.fromJson(decoded['usage']),
            );
          }
        }
      }
      throw LlmException('Unknown opencode response: ${_truncate(raw, 200)}');
    } on LlmException {
      rethrow;
    } catch (e) {
      throw LlmException('Failed to read response: ${_truncate(raw, 600)}');
    }
  }

  Future<AssistantTurn> _parseSse(
    http.ByteStream stream,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
  ) async {
    final StringBuffer content = StringBuffer();
    final Map<int, _ToolAccumulator> tools = <int, _ToolAccumulator>{};
    TokenUsage? usage;
    var lineBuffer = '';
    var done = false;
    var aborted = false;

    try {
      await for (final chunk in stream.transform(utf8.decoder)) {
        if (shouldAbort?.call() ?? false) {
          aborted = true;
          break;
        }
        lineBuffer += chunk;
        while (true) {
          final int newlineIndex = lineBuffer.indexOf('\n');
          if (newlineIndex < 0) break;
          final String line = lineBuffer.substring(0, newlineIndex).trim();
          lineBuffer = lineBuffer.substring(newlineIndex + 1);
          if (line.isEmpty || line.startsWith(':')) continue;
          if (!line.startsWith('data:')) continue;
          final String data = line.substring(5).trim();
          if (data == '[DONE]') {
            done = true;
            break;
          }
          Map<String, dynamic> event;
          try {
            final dynamic decoded = jsonDecode(data);
            if (decoded is! Map<String, dynamic>) continue;
            event = decoded;
          } catch (_) {
            continue;
          }
          // Capture usage even on a chunk with no choices (final
          // include_usage emission).
          final Object? eventUsage = event['usage'];
          if (eventUsage is Map<String, dynamic>) {
            usage = TokenUsage.fromJson(eventUsage) ?? usage;
          }
          final choices = event['choices'];
          if (choices is! List || choices.isEmpty) continue;
          final delta = choices.first['delta'];
          if (delta is! Map<String, dynamic>) continue;
          final Object? text = delta['content'];
          if (text is String && text.isNotEmpty) {
            content.write(text);
            onDelta?.call(text);
          }
          final Object? toolCalls = delta['tool_calls'];
          if (toolCalls is List) {
            for (final raw in toolCalls) {
              if (raw is! Map<String, dynamic>) continue;
              final int index = (raw['index'] as int?) ?? tools.length;
              final _ToolAccumulator acc = tools.putIfAbsent(
                index,
                _ToolAccumulator.new,
              );
              if (raw['id'] is String && (acc.id == null || acc.id!.isEmpty)) {
                acc.id = raw['id'] as String;
              }
              final function = raw['function'];
              if (function is Map<String, dynamic>) {
                final name = function['name'];
                if (name is String &&
                    name.isNotEmpty &&
                    (acc.name == null || acc.name!.isEmpty)) {
                  acc.name = name;
                }
                final arguments = function['arguments'];
                if (arguments is String) acc.arguments.write(arguments);
              }
            }
          }
        }
        if (done) break;
      }
    } on LlmException {
      rethrow;
    } catch (e) {
      // Dropped socket mid-stream: keep usable partial text, never
      // half-received tool calls (their JSON would be truncated).
      if (tools.isEmpty && content.isNotEmpty) {
        return AssistantTurn(content: content.toString());
      }
      throw LlmException('Connection lost while streaming: $e');
    }
    if (aborted) throw LlmAbortedException(content.toString());

    final ordered = tools.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return AssistantTurn(
      content: content.toString(),
      usage: usage,
      toolCalls: <ToolCallRequest>[
        for (final entry in ordered)
          if (entry.value.name != null) entry.value.toRequest(),
      ],
    );
  }

  List<ToolCallRequest> _parseFullToolCalls(Object? rawToolCalls) {
    if (rawToolCalls is! List) return const <ToolCallRequest>[];
    final out = <ToolCallRequest>[];
    for (final raw in rawToolCalls) {
      if (raw is! Map<String, dynamic>) continue;
      final function = raw['function'];
      if (function is! Map<String, dynamic>) continue;
      final Object? name = function['name'];
      if (name == null || name.toString().isEmpty) continue;
      out.add(
        ToolCallRequest(
          id: raw['id']?.toString() ?? newCallId(),
          name: name.toString(),
          argumentsJson: (function['arguments'] ?? '').toString(),
        ),
      );
    }
    return out;
  }
}

String _truncate(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}...';

class _ToolAccumulator {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();

  ToolCallRequest toRequest() => ToolCallRequest(
    id: (id == null || id!.isEmpty) ? newCallId() : id!,
    name: name!,
    argumentsJson: arguments.toString(),
  );
}

/// True when [error] is worth another automatic attempt: transport
/// failures (unreachable server, dropped stream, socket/timeout) and
/// transient HTTP responses (408/425/429 and all 5xx). Auth and
/// bad-request errors are permanent — retrying them only burns the budget.
/// A user-initiated [LlmAbortedException] (Stop) is never retried.
bool isRetryableOpencodeError(Object? error) {
  if (error is LlmAbortedException) return false;
  if (error is LlmException) {
    final int? code = error.statusCode;
    if (code != null) {
      return code == 408 ||
          code == 425 ||
          code == 429 ||
          (code >= 500 && code <= 599);
    }
    final String m = error.message.toLowerCase();
    return m.contains('could not connect') ||
        m.contains('connection lost') ||
        m.contains('failed to read response') ||
        m.contains('timeout');
  }
  return error is SocketException ||
      error is HttpException ||
      error is TimeoutException;
}
