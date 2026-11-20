// Integration test: the model chip renders the runtime-ready dot against a
// fake embedded-opencode runtime and a loopback [MockOpencodeServer].
//
// Full app boot (OAgentsApp → LockGate → HomeShell) needs SharedPreferences,
// the cron scheduler, the app-lock prefs, the IP-guard prefs and the embedded
// opencode runtime to all be wired — too heavy for a hermetic host run and
// not needed to prove the contract under test. Per the test plan's fallback,
// this pumps just [ModelChip] inside a [ProviderScope] that overrides:
//   * opencodeRuntimeProvider → FakeOpencodeRuntimeBridge (state = running)
//   * opencodeClientProvider   → OpencodeClient (would talk to the mock server)
//   * settingsRepositoryProvider → MemorySettingsRepository (opencodeModel set)
//
// It asserts the runtime-ready green dot renders (the chip doubles as a
// runtime-health indicator) and that the old "missing API key" error path is
// gone (the missingApiKey string now mentions opencode, not API key).

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:oagents/di.dart';
import 'package:oagents/l10n/app_strings.dart';
import 'package:oagents/models/models.dart';
import 'package:oagents/services/opencode_client.dart';
import 'package:oagents/services/opencode_runtime.dart';
import 'package:oagents/services/settings_repository.dart';
import 'package:oagents/ui/theme.dart';
import 'package:oagents/ui/widgets/model_picker.dart';

import '../test/support/mock_opencode_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late MockOpencodeServer server;

  setUpAll(() async {
    server = await MockOpencodeServer.start();
  });

  tearDownAll(() async {
    await server.close();
  });

  testWidgets(
    'ModelChip shows the runtime-ready dot and no missing-API-key error',
    (WidgetTester tester) async {
      final FakeOpencodeRuntimeBridge runtime = FakeOpencodeRuntimeBridge();
      // Sanity: the fake is running, so the chip's `ready` select is true.
      expect(runtime.currentStatus.isReady, isTrue);

      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          opencodeRuntimeProvider.overrideWithValue(runtime),
          opencodeClientProvider.overrideWithValue(OpencodeClient()),
          settingsRepositoryProvider.overrideWithValue(
            MemorySettingsRepository(
              AppSettings(opencodeModel: 'opencode/glm-4.6'),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildDarkTheme(),
            locale: const Locale('en'),
            supportedLocales: const <Locale>[
              Locale('en'),
              Locale('id'),
              Locale('es'),
            ],
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              zLocalizationsDelegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const Scaffold(body: ModelChip()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. The model chip renders and shows the configured opencode model id.
      expect(find.byKey(const Key('model-chip')), findsOneWidget);
      expect(find.text('opencode/glm-4.6'), findsOneWidget);

      // 2. The runtime-ready dot is green (kAccentColor) because the fake
      //    bridge reports state = running. ModelChip paints exactly one
      //    Icons.circle (size 7) as the health dot.
      final Icon dot = tester.widget(find.byIcon(Icons.circle)) as Icon;
      expect(
        dot.color,
        kAccentColor,
        reason: 'runtime is running → the chip dot must be the accent color',
      );

      // 3. The old "missing API key" error path is gone: nothing in the tree
      //    mentions an API key (the missingApiKey string now talks about the
      //    opencode runtime instead).
      expect(find.textContaining('API key'), findsNothing);
      expect(find.textContaining('api key'), findsNothing);
    },
  );
}
