// Minimal localization tests for the opencode-only world.
//
// OAgents has exactly one AI backend (an embedded opencode CLI), so the old
// "missing API key" controller message was repurposed: [AppStrings.missingApiKey]
// now reports that the embedded opencode runtime is not running (the real
// boot/config failure mode in the new architecture). This test locks down that
// the getter in en/id/es all mention "opencode" (case-insensitive) — the
// string the chat gate surfaces when the runtime is not ready.
//
// `appStringsFor` is the context-free factory in lib/l10n/app_strings.dart
// (controllers use it because they have no BuildContext).

import 'package:flutter_test/flutter_test.dart';
import 'package:oagents/l10n/app_strings.dart';
import 'package:oagents/l10n/app_strings_es.dart';

void main() {
  group('missingApiKey mentions opencode in every locale', () {
    test('en', () {
      final AppStrings s = appStringsFor('en');
      expect(s, isA<AppStringsEn>());
      expect(s.missingApiKey.toLowerCase(), contains('opencode'));
    });

    test('id', () {
      final AppStrings s = appStringsFor('id');
      expect(s, isA<AppStringsId>());
      expect(s.missingApiKey.toLowerCase(), contains('opencode'));
    });

    test('es', () {
      final AppStrings s = appStringsFor('es');
      expect(s, isA<AppStringsEs>());
      expect(s.missingApiKey.toLowerCase(), contains('opencode'));
    });

    test('unknown codes fall back to English (which also mentions opencode)',
        () {
      expect(appStringsFor('xx'), isA<AppStringsEn>());
      expect(
        appStringsFor('').missingApiKey.toLowerCase(),
        contains('opencode'),
      );
      // Case-insensitive resolution.
      expect(appStringsFor('ID'), isA<AppStringsId>());
      expect(appStringsFor('ES'), isA<AppStringsEs>());
    });
  });
}
