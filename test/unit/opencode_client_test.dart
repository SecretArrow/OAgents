// Unit tests for [OpencodeClient] against the in-process [MockOpencodeServer].
//
// These run as plain `test()` bodies (no widget binding) so real IO — the
// loopback HttpServer and the client's `Isolate.run` body encode — progresses
// normally. Each test starts its own ephemeral mock server and tears it down.
//
// Covers the opencode HTTP/SSE contract documented in
// `lib/services/opencode_client.dart`: ping, listModels, chatStream text +
// tool-call accumulation, 401 handling and abort via `shouldAbort`.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oagents/services/llm_client.dart';
import 'package:oagents/services/opencode_client.dart';

import '../support/mock_opencode_server.dart';

void main() {
  late MockOpencodeServer server;
  late OpencodeClient client;

  setUp(() async {
    server = await MockOpencodeServer.start();
    client = OpencodeClient(); // real http.Client against loopback
  });

  tearDown(() async {
    await server.close();
  });

  group('ping', () {
    test('returns true when the server is up', () async {
      expect(
        await client.ping(
          serverUrl: server.base,
          timeout: const Duration(seconds: 2),
        ),
        isTrue,
      );
    });

    test('returns false when pointing at a closed port', () async {
      // Bind a server on an ephemeral port, capture the port, then close it so
      // nothing is listening there anymore.
      final HttpServer probe = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int closedPort = probe.port;
      await probe.close(force: true);

      expect(
        await client.ping(
          serverUrl: 'http://127.0.0.1:$closedPort',
          timeout: const Duration(seconds: 2),
        ),
        isFalse,
        reason: 'a closed port must report not-up, never throw',
      );
    });
  });

  group('listModels', () {
    test('returns the two advertised models in order', () async {
      final List<OpencodeModel> models = await client.listModels(
        serverUrl: server.base,
        timeout: const Duration(seconds: 4),
      );
      expect(models, hasLength(2));
      expect(models[0].id, 'opencode/glm-4.6');
      expect(models[0].name, 'GLM-4.6');
      expect(models[1].id, 'opencode/claude-sonnet-4.5');
      expect(models[1].name, 'Claude Sonnet 4.5');
    });
  });

  group('chatStream', () {
    test('streams two text chunks and returns the concatenated turn', () async {
      final List<String> deltas = <String>[];
      final AssistantTurn turn = await client.chatStream(
        config: LlmConfig(
          serverUrl: server.base,
          authToken: '',
          model: 'opencode/glm-4.6',
        ),
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
        onDelta: deltas.add,
      );

      // The mock splits "Hello from embedded opencode" into two chunks.
      expect(deltas, hasLength(2));
      expect(deltas.first, 'Hello ');
      expect(deltas.last, 'from embedded opencode');
      expect(turn.content, 'Hello from embedded opencode');
      expect(turn.toolCalls, isEmpty);
      // Usage chunk (empty choices) is captured.
      expect(turn.usage, isNotNull);
      expect(turn.usage!.promptTokens, 12);
      expect(turn.usage!.completionTokens, 4);
      expect(turn.usage!.totalTokens, 16);
    });

    test('returns a tool call when the prompt contains "tool"', () async {
      final AssistantTurn turn = await client.chatStream(
        config: LlmConfig(
          serverUrl: server.base,
          authToken: '',
          model: 'opencode/glm-4.6',
        ),
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': 'please use a tool to open example.com',
          },
        ],
      );

      expect(turn.toolCalls, hasLength(1));
      final ToolCallRequest call = turn.toolCalls.single;
      expect(call.id, 'call_test1');
      expect(call.name, 'browser_navigate');
      expect(call.args['url'], 'https://example.com');
      // The text chunks are still streamed after the tool call.
      expect(turn.content, 'Hello from embedded opencode');
    });

    test(
      'throws LlmException with statusCode 401 when authToken is "deny"',
      () async {
        await expectLater(
          client.chatStream(
            config: LlmConfig(
              serverUrl: server.base,
              authToken: 'deny',
              model: 'opencode/glm-4.6',
            ),
            messages: const <Map<String, dynamic>>[
              <String, dynamic>{'role': 'user', 'content': 'hi'},
            ],
          ),
          throwsA(
            isA<LlmException>().having(
              (LlmException e) => e.statusCode,
              'statusCode',
              401,
            ),
          ),
        );
      },
    );

    test('throws LlmAbortedException with the partial content streamed so far '
        'when shouldAbort flips true mid-stream', () async {
      // Separate the chunks in time so the client's per-read shouldAbort
      // poll fires after the first chunk and before the second.
      server.chunkDelay = const Duration(milliseconds: 60);

      bool abort = false;
      final List<String> seen = <String>[];
      // Flip the abort flag as soon as the first text delta arrives.
      void onDelta(String delta) {
        seen.add(delta);
        if (!abort) abort = true;
      }

      await expectLater(
        client.chatStream(
          config: LlmConfig(
            serverUrl: server.base,
            authToken: '',
            model: 'opencode/glm-4.6',
          ),
          messages: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
          onDelta: onDelta,
          shouldAbort: () => abort,
        ),
        throwsA(
          isA<LlmAbortedException>().having(
            (LlmAbortedException e) => e.partialContent,
            'partialContent',
            allOf(
              // The first chunk ("Hello ") was streamed before the abort.
              contains('Hello'),
              // The second chunk never made it: the abort fired first.
              isNot(contains('from embedded')),
            ),
          ),
        ),
      );
      // Sanity: at least the first delta was observed.
      expect(seen, isNotEmpty);
    });
  });
}
