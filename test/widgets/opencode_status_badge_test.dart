// Widget test: the v1.0.6 OpencodeStatusBadge — the always-visible
// opencode runtime indicator in the main app bar.
//
// The badge subscribes to the runtime status stream and renders one dot +
// label per lifecycle state; a boot (extracting/starting) shows a pulsing
// dot, running shows a green dot + version, failed a red dot. Tapping it
// opens the opencode setup screen. All assertions are against a
// FakeOpencodeRuntimeBridge so no platform channel or real server is needed
// (same hermetic pattern as e2e_test.dart).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oagents/di.dart';
import 'package:oagents/services/opencode_runtime.dart';
import 'package:oagents/ui/theme.dart';
import 'package:oagents/ui/widgets/opencode_status_badge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Bare MaterialApp host — NO ProviderScope here: each test wraps this in
  // its own ProviderScope with the fake-bridge override, so the badge reads
  // the overridden provider (a nested scope here would shadow it and the
  // badge would get the real platform-channel bridge).
  Widget host(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildDarkTheme(),
    home: Scaffold(appBar: AppBar(actions: <Widget>[child])),
  );

  Widget harness(Widget child, FakeOpencodeRuntimeBridge runtime) =>
      ProviderScope(
        overrides: <Override>[
          opencodeRuntimeProvider.overrideWithValue(runtime),
        ],
        child: host(child),
      );

  testWidgets('badge shows version when running', (WidgetTester tester) async {
    final FakeOpencodeRuntimeBridge runtime = FakeOpencodeRuntimeBridge(
      initial: const OpencodeRuntimeStatus(
        state: OpencodeRuntimeState.running,
        version: 'opencode-abc1234',
      ),
    );
    await tester.pumpWidget(harness(const OpencodeStatusBadge(), runtime));
    await tester.pumpAndSettle();
    expect(find.text('opencode opencode-abc1234'), findsOneWidget);
    // No pulsing animation while running (nothing animates → settles).
    await tester.pumpAndSettle();
    runtime.dispose();
  });

  testWidgets('badge shows boot label + pulsing dot while starting', (
    WidgetTester tester,
  ) async {
    final FakeOpencodeRuntimeBridge runtime = FakeOpencodeRuntimeBridge(
      initial: const OpencodeRuntimeStatus(
        state: OpencodeRuntimeState.starting,
      ),
    );
    await tester.pumpWidget(harness(const OpencodeStatusBadge(), runtime));
    expect(find.text('opencode …'), findsOneWidget);
    // The pulsing dot animates forever — pumpAndSettle must time out, and a
    // frame advance must keep the widget tree alive (no crash).
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('opencode …'), findsOneWidget);
    runtime.dispose();
  });

  testWidgets('badge transitions live: starting → running flips the label', (
    WidgetTester tester,
  ) async {
    final FakeOpencodeRuntimeBridge runtime = FakeOpencodeRuntimeBridge(
      initial: const OpencodeRuntimeStatus(
        state: OpencodeRuntimeState.starting,
      ),
    );
    await tester.pumpWidget(harness(const OpencodeStatusBadge(), runtime));
    expect(find.text('opencode …'), findsOneWidget);
    runtime.emit(
      const OpencodeRuntimeStatus(
        state: OpencodeRuntimeState.running,
        version: 'v9',
      ),
    );
    await tester.pump();
    expect(find.text('opencode v9'), findsOneWidget);
    expect(find.text('opencode …'), findsNothing);
    runtime.dispose();
  });

  testWidgets('badge shows failed label and stopped label', (
    WidgetTester tester,
  ) async {
    final FakeOpencodeRuntimeBridge runtime = FakeOpencodeRuntimeBridge(
      initial: const OpencodeRuntimeStatus(
        state: OpencodeRuntimeState.failed,
        message: 'boom',
      ),
    );
    await tester.pumpWidget(harness(const OpencodeStatusBadge(), runtime));
    expect(find.text('opencode ✕'), findsOneWidget);
    runtime.emit(
      const OpencodeRuntimeStatus(state: OpencodeRuntimeState.stopped),
    );
    await tester.pump();
    expect(find.text('opencode off'), findsOneWidget);
    runtime.dispose();
  });

  testWidgets('extracting shows the boot label too', (
    WidgetTester tester,
  ) async {
    final FakeOpencodeRuntimeBridge runtime = FakeOpencodeRuntimeBridge(
      initial: const OpencodeRuntimeStatus(
        state: OpencodeRuntimeState.extracting,
      ),
    );
    await tester.pumpWidget(harness(const OpencodeStatusBadge(), runtime));
    expect(find.text('opencode …'), findsOneWidget);
    runtime.dispose();
  });
}
