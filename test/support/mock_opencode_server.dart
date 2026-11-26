// Mock opencode HTTP server for the OAgents test suite.
//
// Implements the exact wire contract documented in
// `lib/services/opencode_client.dart`:
//
//   GET  /health             → 204 (connection probe, no body)
//   GET  /models             → {"data":[{"id":"opencode/glm-4.6","name":"GLM-4.6"},
//                                      {"id":"opencode/claude-sonnet-4.5","name":"Claude Sonnet 4.5"}]}
//   POST /chat/completions   → SSE `text/event-stream`
//
// The default `/chat/completions` behavior streams a fixed assistant reply
// "Hello from embedded opencode" in two text chunks, then a usage chunk, then
// `data: [DONE]`. When the request body's last user message contains the word
// "tool" (case-insensitive), a single tool_call delta
// (`browser_navigate` → `{"url":"https://example.com"}`, id `call_test1`) is
// streamed BEFORE the text chunks. When the `Authorization` header equals
// `Bearer deny`, the server responds 401.
//
// The server is a pure-Dart [HttpServer] bound on the loopback interface, so
// it imports nothing from `package:flutter` and runs under both `flutter test`
// (unit/widget tests) and a bare `dart test` harness — no device required.
// Tests that need the request alive mid-stream (force-cancel, abort) raise
// [chunkDelay] so the chunks arrive separated in time.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A scriptable in-process opencode server for tests.
///
/// Start with [MockOpencodeServer.start], drive [OpencodeClient] / [LlmClient]
/// against [base], stop with [close]. The SSE behavior follows the contract
/// documented at the top of this file; the only tunable is [chunkDelay].
class MockOpencodeServer {
  HttpServer? _server;
  int _port = 0;

  /// Delay inserted between SSE chunks. Default zero (all chunks flushed back
  /// to back). Tests that exercise abort/force-cancel set this so the stream
  /// is still alive when the cancel fires and so chunks arrive as separate
  /// transport reads (the client's `shouldAbort` poll runs once per read).
  Duration chunkDelay = Duration.zero;

  /// Number of `/chat/completions` requests received (any outcome).
  int chatCalls = 0;

  /// v1.0.8: when set, the streaming reply pins this opencode session id
  /// in its first chunk even when the request carried none (simulates the
  /// adapter minting a session for a fresh chat). Tests assert the client
  /// captures it on the returned AssistantTurn.
  String? pinnedSessionIdForChat;

  /// Binds the server on `127.0.0.1` on [port] (0 = ephemeral) and returns
  /// the started instance. After this returns, [base] is usable.
  static Future<MockOpencodeServer> start({int port = 0}) async {
    final MockOpencodeServer instance = MockOpencodeServer();
    instance._server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    instance._port = instance._server!.port;
    unawaited(instance._serve());
    return instance;
  }

  /// Stops accepting connections and closes every live socket.
  Future<void> close() async {
    final HttpServer? server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {
        // Best-effort teardown — never mask a test failure.
      }
    }
  }

  /// Base URL of the running server, e.g. `http://127.0.0.1:41921`.
  String get base => 'http://127.0.0.1:$_port';

  // --- Server loop ---------------------------------------------------------

  Future<void> _serve() async {
    final HttpServer server = _server!;
    try {
      await for (final HttpRequest request in server) {
        try {
          await _handle(request);
        } catch (_) {
          // A force-cancel closes the socket mid-write: the next IO call
          // throws. Swallow so the server keeps serving other tests.
          try {
            await request.response.close();
          } catch (_) {
            // already torn down
          }
        }
      }
    } catch (_) {
      // server closed — exit the loop.
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final String path = request.uri.path;
    if (path.startsWith('/api/session')) {
      await _apiSession(request, path);
      return;
    }
    switch (path) {
      case '/health':
        _health(request);
        return;
      case '/models':
        _models(request);
        return;
      case '/chat/completions':
        chatCalls++;
        await _chat(request);
        return;
      default:
        _notFound(request);
        return;
    }
  }

  /// v1.0.8: minimal opencode /api/session surface the app talks to
  /// through the adapter's verbatim /api/* passthrough:
  ///
  ///   GET  /api/session            → {"data":[Session.Info,…]}
  ///   POST /api/session            → {"data":{…new session…}}
  ///   POST /api/session/{id}/model → 204, records the switch
  ///
  /// Created sessions get ids `ses_test_<n>`; [sessionModels] maps a
  /// session id to its last-switched model so tests can assert switches.
  final Map<String, String> sessionModels = <String, String>{};
  final List<Map<String, dynamic>> _sessions = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'ses_test_cli_1',
      'title': 'CLI session one',
      'model': <String, dynamic>{'providerID': 'opencode', 'id': 'glm-4.6'},
      'time': <String, dynamic>{'created': 1730000000, 'updated': 1730000500},
    },
  ];

  Future<void> _apiSession(HttpRequest request, String path) async {
    final HttpResponse res = request.response;
    if (request.method == 'GET' && path == '/api/session') {
      res.statusCode = HttpStatus.ok;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(<String, dynamic>{'data': _sessions}));
      await res.close();
      return;
    }
    if (request.method == 'POST' && path == '/api/session') {
      final int n = _sessions.length + 1;
      final Map<String, dynamic> s = <String, dynamic>{
        'id': 'ses_test_$n',
        'title': '',
        'time': <String, dynamic>{
          'created': 1730001000 + n,
          'updated': 1730001000 + n,
        },
      };
      _sessions.add(s);
      res.statusCode = HttpStatus.ok;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(<String, dynamic>{'data': s}));
      await res.close();
      return;
    }
    // POST /api/session/{id}/model
    final Match? m = RegExp(r'^/api/session/([^/]+)/model$').firstMatch(path);
    if (request.method == 'POST' && m != null) {
      final String id = m.group(1)!;
      sessionModels[id] = 'switched';
      res.statusCode = HttpStatus.noContent;
      res.contentLength = 0;
      await res.close();
      return;
    }
    _notFound(request);
  }

  void _health(HttpRequest request) {
    final HttpResponse res = request.response;
    res.statusCode = HttpStatus.noContent; // 204
    res.contentLength = 0;
    res.close();
  }

  void _models(HttpRequest request) {
    final HttpResponse res = request.response;
    res.statusCode = HttpStatus.ok;
    res.headers.contentType = ContentType.json;
    res.write(
      jsonEncode(<String, dynamic>{
        'data': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'opencode/glm-4.6', 'name': 'GLM-4.6'},
          <String, dynamic>{
            'id': 'opencode/claude-sonnet-4.5',
            'name': 'Claude Sonnet 4.5',
          },
        ],
      }),
    );
    res.close();
  }

  Future<void> _chat(HttpRequest request) async {
    final HttpResponse res = request.response;

    // Read+decode the request body so we can branch on the last user message.
    // OpencodeClient sends `stream: true` and a JSON body; the body is small
    // (test fixture), so a full byte read is fine.
    final List<int> bodyBytes = await request.fold<List<int>>(
      <int>[],
      (List<int> prev, List<int> chunk) => prev..addAll(chunk),
    );
    String lastUserContent = '';
    bool streamFlag = true;
    String requestSessionId = '';
    String requestModel = '';
    try {
      final dynamic decoded = jsonDecode(utf8.decode(bodyBytes));
      if (decoded is Map<String, dynamic>) {
        final Object? stream = decoded['stream'];
        if (stream is bool) streamFlag = stream;
        // v1.0.8 session pinning fields (adapter contract): a pinned run
        // reuses the chat's opencode session; a model switch applies to
        // that session. Both are echoed back so tests can assert them.
        final Object? sid = decoded['sessionID'];
        if (sid is String) requestSessionId = sid;
        final Object? m = decoded['model'];
        if (m is String) requestModel = m;
        final Object? messages = decoded['messages'];
        if (messages is List) {
          for (final Object? m in messages) {
            if (m is Map<String, dynamic> && m['role'] == 'user') {
              final Object? c = m['content'];
              if (c is String) lastUserContent = c;
            }
          }
        }
      }
    } catch (_) {
      // Malformed body: fall through to the default streaming reply.
    }

    // Auth gate: `Bearer deny` is the test fixture for a 401.
    final String? auth = request.headers.value('authorization');
    if (auth != null && auth.trim() == 'Bearer deny') {
      res.statusCode = HttpStatus.unauthorized;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(<String, dynamic>{'error': 'unauthorized'}));
      await res.flush();
      await res.close();
      return;
    }

    // If the client explicitly asked for a non-streaming response, honor it
    // with a plain JSON body (the client always sends stream:true; this keeps
    // the contract honest).
    if (!streamFlag) {
      res.statusCode = HttpStatus.ok;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(_nonStreamingPayload(lastUserContent)));
      await res.flush();
      await res.close();
      return;
    }

    // Streaming SSE response.
    res.statusCode = HttpStatus.ok;
    res.headers.contentType = ContentType.parse('text/event-stream');
    res.headers.set('Cache-Control', 'no-cache');
    res.headers.set('Connection', 'keep-alive');
    await res.flush();

    final bool wantsTool = lastUserContent.toLowerCase().contains('tool');

    // v1.0.8: first chunk carries the pinned session id (and, for a fresh
    // chat, the id the adapter minted). Mirrors the embedded adapter so
    // the client's session-capture path is exercised. Only emitted when
    // there is a session to announce — a request without sessionID and
    // without [pinnedSessionIdForChat] must see the exact pre-v1.0.8
    // chunk sequence (the abort/force-cancel tests depend on it).
    final String? announceSession = requestSessionId.isNotEmpty
        ? requestSessionId
        : pinnedSessionIdForChat;
    final List<String> events = <String>[
      if (announceSession != null)
        jsonEncode(<String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'delta': <String, dynamic>{
                'role': 'assistant',
                'sessionID': announceSession,
                if (requestModel.isNotEmpty) 'model': requestModel,
              },
            },
          ],
        }),
    ];
    if (wantsTool) {
      events.add(
        jsonEncode(<String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'delta': <String, dynamic>{
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'index': 0,
                    'id': 'call_test1',
                    'function': <String, dynamic>{
                      'name': 'browser_navigate',
                      'arguments': '{"url":"https://example.com"}',
                    },
                  },
                ],
              },
            },
          ],
        }),
      );
    }
    // Two text chunks whose concatenation is "Hello from embedded opencode".
    events.add(
      jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'delta': <String, dynamic>{'content': 'Hello '},
          },
        ],
      }),
    );
    events.add(
      jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'delta': <String, dynamic>{'content': 'from embedded opencode'},
          },
        ],
      }),
    );
    // Final usage chunk (empty choices) — the include_usage emission.
    events.add(
      jsonEncode(<String, dynamic>{
        'choices': <dynamic>[],
        'usage': <String, dynamic>{'prompt_tokens': 12, 'completion_tokens': 4},
      }),
    );

    for (int i = 0; i < events.length; i++) {
      // Delay BEFORE each flush (including the first) so a test that needs
      // the request still alive mid-stream (force-cancel) can fire before any
      // content chunk is delivered — the client then sees an empty buffer and
      // surfaces the interruption instead of a partial turn.
      if (chunkDelay > Duration.zero) {
        await Future<void>.delayed(chunkDelay);
      }
      try {
        res.add(utf8.encode('data: ${events[i]}\n\n'));
        await res.flush();
      } catch (_) {
        // Socket torn down mid-stream (forceCancel). Bail.
        try {
          await res.close();
        } catch (_) {
          // already closed
        }
        return;
      }
    }
    try {
      res.add(utf8.encode('data: [DONE]\n\n'));
      await res.flush();
      await res.close();
    } catch (_) {
      try {
        await res.close();
      } catch (_) {
        // already closed
      }
    }
  }

  Map<String, dynamic> _nonStreamingPayload(String lastUserContent) {
    final bool wantsTool = lastUserContent.toLowerCase().contains('tool');
    return <String, dynamic>{
      'choices': <Map<String, dynamic>>[
        <String, dynamic>{
          'message': <String, dynamic>{
            'role': 'assistant',
            'content': 'Hello from embedded opencode',
            if (wantsTool)
              'tool_calls': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'call_test1',
                  'type': 'function',
                  'function': <String, dynamic>{
                    'name': 'browser_navigate',
                    'arguments': '{"url":"https://example.com"}',
                  },
                },
              ],
          },
        },
      ],
      'usage': <String, dynamic>{'prompt_tokens': 12, 'completion_tokens': 4},
    };
  }

  void _notFound(HttpRequest request) {
    final HttpResponse res = request.response;
    res.statusCode = HttpStatus.notFound;
    res.contentLength = 0;
    res.close();
  }
}
