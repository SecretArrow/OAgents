// Unit tests for [LlmClient.complete] delegating to [OpencodeClient] against
// the in-process [MockOpencodeServer].
//
// OAgents has exactly one AI backend: an [LlmClient] that streams every turn
// to an opencode server over HTTP. These tests wire [LlmClient] (default
// constructor, real http.Client) to a loopback [MockOpencodeServer] and assert
// the delegation: content streaming, tool-call accumulation, and the static
// [LlmClient.forceCancel] live-stream registry.
//
// Plain `test()` bodies (no widget binding) so real IO and `Isolate.run`
// progress normally. Each test uses a DISTINCT cancelKey so the static
// `_liveStreams` registry never leaks between tests.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:oagents/services/llm_client.dart';

import '../support/mock_opencode_server.dart';

void main() {
  late MockOpencodeServer server;
  late LlmClient client;

  setUp(() async {
    server = await MockOpencodeServer.start();
    client = LlmClient(); // delegates to OpencodeClient(client: real http)
  });

  tearDown(() async {
    await server.close();
  });

  LlmConfig config({String authToken = ''}) => LlmConfig(
    serverUrl: server.base,
    authToken: authToken,
    model: 'opencode/glm-4.6',
  );

  test('complete streams the assistant reply and captures usage', () async {
    final List<String> deltas = <String>[];
    final AssistantTurn turn = await client.complete(
      config: config(),
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': 'hi'},
      ],
      onDelta: deltas.add,
    );

    expect(deltas, hasLength(2));
    expect(turn.content, 'Hello from embedded opencode');
    expect(turn.toolCalls, isEmpty);
    expect(turn.usage, isNotNull);
    expect(turn.usage!.totalTokens, 16);
  });

  test(
    'complete returns a tool call when the prompt mentions a tool',
    () async {
      final AssistantTurn turn = await client.complete(
        config: config(),
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': 'open example.com with a browser tool',
          },
        ],
      );

      expect(turn.toolCalls, hasLength(1));
      expect(turn.toolCalls.single.name, 'browser_navigate');
      expect(turn.toolCalls.single.id, 'call_test1');
      expect(turn.toolCalls.single.args['url'], 'https://example.com');
      expect(turn.content, 'Hello from embedded opencode');
    },
  );

  test('forceCancel with a known cancelKey returns true once the stream is '
      'registered (and the in-flight call is interrupted)', () async {
    // Hold the stream open so the registration is still live when the cancel
    // fires: the mock delays before each chunk, so no content has arrived
    // yet at the moment of the cancel.
    server.chunkDelay = const Duration(milliseconds: 300);

    final Object cancelKey = Object();
    final Future<AssistantTurn> f = client.complete(
      config: config(),
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': 'hi'},
      ],
      cancelKey: cancelKey,
    );

    // Let chatStream run its synchronous prefix up to the live-stream
    // registration (which happens before the first `await`) and into the
    // streaming read.
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // The in-flight request is registered → forceCancel finds and kills it.
    expect(LlmClient.forceCancel(cancelKey), isTrue);
    // A second cancel of the same key is a no-op (already removed).
    expect(LlmClient.forceCancel(cancelKey), isFalse);

    // Tearing down the client interrupts the stream: the call either throws,
    // or resolves to a partial/empty turn — it must NEVER resolve to the full
    // "Hello from embedded opencode" reply (that would mean the cancel was a
    // no-op). Both the hard-close error path and a graceful socket end are
    // accepted; only "completed the full reply" is a failure.
    AssistantTurn? turn;
    Object? thrown;
    try {
      turn = await f;
    } catch (e) {
      thrown = e;
    }
    expect(
      thrown != null || turn?.content != 'Hello from embedded opencode',
      isTrue,
      reason:
          'forceCancel must interrupt the in-flight stream (got '
          'thrown=$thrown, content=${turn?.content})',
    );
  });
}
