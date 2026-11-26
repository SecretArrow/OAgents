// v1.0.8 — per-chat model + opencode session integration widget tests.
//
// Covers the two UI pieces of the CLI-semantics rework:
//
//  1. ModelChip shows the CHAT's model override when one exists (beats
//     the app-wide default) and falls back to the default otherwise.
//  2. ModelPickerSheet applies a selection to the ACTIVE chat through
//     ChatController.setChatModel (per-chat, the CLI's /model command)
//     instead of writing the app-wide setting.
//
// The bridge is the FakeOpencodeRuntimeBridge (running), so the chip's
// readiness dot is green. Settings use the in-memory repository; the
// chat store is MemoryChatStore so openChat completes inside the test
// zone (an ACTIVE chat is what makes the pick per-chat).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:oagents/di.dart';
import 'package:oagents/l10n/app_strings.dart';
import 'package:oagents/models/models.dart';
import 'package:oagents/services/agent_controller.dart';
import 'package:oagents/services/chat_store.dart';
import 'package:oagents/services/opencode_client.dart';
import 'package:oagents/services/opencode_runtime.dart';
import 'package:oagents/services/settings_repository.dart';
import 'package:oagents/ui/widgets/model_picker.dart';

import '../support/test_doubles.dart';

class _ScriptedClient implements OpencodeClient {
  _ScriptedClient(this.models);

  final List<OpencodeModel> models;
  String? lastSessionModelCall;

  @override
  Future<List<OpencodeModel>> listModels({
    required String serverUrl,
    String authToken = '',
    Duration timeout = const Duration(seconds: 8),
  }) async => models;

  @override
  Future<void> setSessionModel({
    required String serverUrl,
    required String sessionId,
    required String modelId,
    String authToken = '',
    Duration timeout = const Duration(seconds: 8),
  }) async {
    lastSessionModelCall = '$sessionId|$modelId';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<ProviderContainer> _pumpChip(
  WidgetTester tester, {
  OpencodeClient? client,
}) async {
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(
          MemorySettingsRepository(),
        ),
        chatStoreProvider.overrideWithValue(MemoryChatStore()),
        opencodeRuntimeProvider.overrideWithValue(FakeOpencodeRuntimeBridge()),
        if (client != null) opencodeClientProvider.overrideWithValue(client),
      ],
      child: Builder(
        builder: (BuildContext context) {
          container = ProviderScope.containerOf(context);
          return MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              zLocalizationsDelegate,
            ],
            supportedLocales: const <Locale>[Locale('en'), Locale('id')],
            home: const Scaffold(body: ModelChip()),
          );
        },
      ),
    ),
  );
  await tester.pump();
  // An ACTIVE chat is what routes the pick through setChatModel.
  await container
      .read(chatControllerProvider.notifier)
      .openChat(
        ChatSummary(
          id: 'chat-1',
          title: 'Test chat',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
      );
  await tester.pump();
  return container;
}

void main() {
  testWidgets('ModelChip prefers the chat model over the app default', (
    tester,
  ) async {
    final container = await _pumpChip(tester);

    // App-wide default.
    await container
        .read(settingsProvider.notifier)
        .update(
          container
              .read(settingsProvider)
              .copyWith(opencodeModel: 'opencode/x'),
        );
    await tester.pump();
    expect(find.text('opencode/x'), findsOneWidget);

    // The chat overrides it — the chip must flip without a settings write.
    await container
        .read(chatControllerProvider.notifier)
        .setChatModel('opencode/glm-4.6');
    await tester.pump();
    expect(find.text('opencode/glm-4.6'), findsOneWidget);
    expect(find.text('opencode/x'), findsNothing);
  });

  testWidgets('ModelPickerSheet applies the pick to the active chat', (
    tester,
  ) async {
    final client = _ScriptedClient(<OpencodeModel>[
      const OpencodeModel(id: 'opencode/glm-4.6', name: 'GLM-4.6'),
      const OpencodeModel(
        id: 'opencode/claude-sonnet-4.5',
        name: 'Claude Sonnet 4.5',
      ),
    ]);
    final container = await _pumpChip(tester, client: client);

    // Open the picker sheet through the chip.
    await tester.tap(find.byKey(const Key('model-chip')));
    await tester.pumpAndSettle();

    // Pick the first catalog entry.
    await tester.tap(find.text('opencode/glm-4.6').last);
    await tester.pumpAndSettle();

    // Per-chat selection: the chat state carries it (not the app setting).
    expect(
      container.read(chatControllerProvider).opencodeModel,
      'opencode/glm-4.6',
    );
    expect(container.read(settingsProvider).opencodeModel, isEmpty);
  });
}
