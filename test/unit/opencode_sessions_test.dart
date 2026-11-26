// v1.0.8 — opencode session integration (CLI semantics) unit tests.
//
// Covers the three pieces of the session-pinning contract against the
// mock opencode server:
//
//  1. listSessions parses GET /api/session rows (the CLI's session list)
//     into OpencodeSession, including the provider/model split.
//  2. setSessionModel POSTs the CLI's /model command shape
//     ({model:{providerID,id}}) and surfaces failures.
//  3. chatStream pins the turn to config.sessionId (body.sessionID),
//     echoes the model, and CAPTURES the session id announced by the
//     stream's first chunk on the returned AssistantTurn — the mechanism
//     the app uses to persist a chat's opencode session after turn one.
import 'package:flutter_test/flutter_test.dart';

import 'package:oagents/services/llm_client.dart';
import 'package:oagents/services/opencode_client.dart';

import '../support/mock_opencode_server.dart';

void main() {
  late MockOpencodeServer server;
  late OpencodeClient client;

  setUp(() async {
    server = await MockOpencodeServer.start();
    client = OpencodeClient();
  });

  tearDown(() async {
    await server.close();
  });

  group('listSessions', () {
    test('parses the CLI session list with model and timestamps', () async {
      final sessions = await client.listSessions(serverUrl: server.base);
      expect(sessions, hasLength(1));
      final s = sessions.single;
      expect(s.id, 'ses_test_cli_1');
      expect(s.title, 'CLI session one');
      expect(s.model, 'opencode/glm-4.6');
      expect(
        s.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1730000500 * 1000),
      );
    });

    test('empty list on server error (never throws)', () async {
      final sessions = await client.listSessions(
        serverUrl: 'http://127.0.0.1:1',
      );
      expect(sessions, isEmpty);
    });
  });

  group('setSessionModel', () {
    test('switches with the CLI /model command shape', () async {
      await client.setSessionModel(
        serverUrl: server.base,
        sessionId: 'ses_test_cli_1',
        modelId: 'opencode/claude-sonnet-4.5',
      );
      expect(server.sessionModels['ses_test_cli_1'], 'switched');
    });

    test('model id without slash defaults provider to opencode', () async {
      await client.setSessionModel(
        serverUrl: server.base,
        sessionId: 'ses_test_cli_1',
        modelId: 'glm-4.6',
      );
      expect(server.sessionModels['ses_test_cli_1'], 'switched');
    });
  });

  group('chatStream session pinning', () {
    test('sends sessionID + model and captures the echoed id', () async {
      final turn = await client.chatStream(
        config: LlmConfig(
          serverUrl: server.base,
          authToken: '',
          model: 'opencode/glm-4.6',
          sessionId: 'ses_pin_1',
        ),
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hello'},
        ],
      );
      expect(turn.content, contains('Hello from embedded opencode'));
      // The first chunk's delta.sessionID lands on the returned turn.
      expect(turn.sessionId, 'ses_pin_1');
    });

    test('captures a freshly minted session id when none was sent', () async {
      server.pinnedSessionIdForChat = 'ses_minted_9';
      final turn = await client.chatStream(
        config: LlmConfig(serverUrl: server.base, authToken: '', model: ''),
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hello'},
        ],
      );
      expect(turn.sessionId, 'ses_minted_9');
    });
  });
}
