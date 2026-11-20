// Unit tests for the new [AppSettings] (opencode-only schema) and the
// behavior-field clamp helpers.
//
// OAgents has exactly ONE AI backend — an embedded opencode CLI — so
// [AppSettings] carries only `opencodeModel` plus behavior toggles. The legacy
// multi-provider fields (apiKey, baseUrl, engine, providerName, presets,
// providerPresets, ProviderPreset, presetHostLabel, LlmEngine,
// llmEngineFromName) are GONE. These tests lock that contract down:
//  * defaults (opencodeModel == '')
//  * copyWith(opencodeModel: ...)
//  * toJson contains 'opencodeModel' and NOT the deleted legacy keys
//  * fromJson round-trip
//  * legacy migration from {'model': '...'} → opencodeModel
//  * clampMaxSteps / clampAutoRetryAttempts / clampAutoRetryDelay bounds

import 'package:flutter_test/flutter_test.dart';
import 'package:oagents/models/models.dart';

void main() {
  group('AppSettings defaults', () {
    test('opencodeModel defaults to empty (let opencode pick its default)', () {
      final AppSettings s = AppSettings();
      expect(s.opencodeModel, '');
    });

    test('behavior fields ship their documented defaults', () {
      final AppSettings s = AppSettings();
      expect(s.agentMode, isTrue);
      expect(s.automationEnabled, isTrue);
      expect(s.maxSteps, defaultMaxSteps);
      expect(s.runUntilDone, isTrue);
      expect(s.planFirst, isTrue);
      expect(s.runInBackground, isTrue);
      expect(s.autoRetryEnabled, isTrue);
      expect(s.autoRetryAttempts, defaultAutoRetryAttempts);
      expect(s.autoRetryDelay, defaultAutoRetryDelay);
      expect(s.deviceCommandsEnabled, isFalse);
      expect(s.themeMode, ThemeModeSetting.dark);
      expect(s.languageCode, 'en');
    });
  });

  group('AppSettings copyWith', () {
    test('copyWith(opencodeModel: x) changes only the model id', () {
      final AppSettings base = AppSettings();
      final AppSettings updated = base.copyWith(
        opencodeModel: 'opencode/glm-4.6',
      );
      expect(updated.opencodeModel, 'opencode/glm-4.6');
      // Untouched fields stay at their defaults.
      expect(updated.agentMode, base.agentMode);
      expect(updated.maxSteps, base.maxSteps);
      expect(updated.runUntilDone, base.runUntilDone);
    });

    test('copyWith clamps maxSteps / autoRetryAttempts / autoRetryDelay', () {
      final AppSettings s = AppSettings().copyWith(
        maxSteps: 9999,
        autoRetryAttempts: 9999,
        autoRetryDelay: 9999,
      );
      expect(s.maxSteps, maxMaxSteps);
      expect(s.autoRetryAttempts, maxAutoRetryAttempts);
      expect(s.autoRetryDelay, maxAutoRetryDelay);
    });
  });

  group('AppSettings JSON', () {
    test("toJson contains 'opencodeModel' and NOT the deleted legacy keys", () {
      final Map<String, dynamic> json = AppSettings(
        opencodeModel: 'opencode/glm-4.6',
      ).toJson();

      expect(json['opencodeModel'], 'opencode/glm-4.6');
      // The multi-provider schema is gone — none of these may survive.
      expect(json.containsKey('apiKey'), isFalse);
      expect(json.containsKey('baseUrl'), isFalse);
      expect(json.containsKey('engine'), isFalse);
      expect(json.containsKey('presets'), isFalse);
      expect(json.containsKey('providerName'), isFalse);
      expect(json.containsKey('authToken'), isFalse);
    });

    test('fromJson round-trips every field', () {
      final AppSettings original = AppSettings(
        opencodeModel: 'opencode/claude-sonnet-4.5',
        agentMode: false,
        maxSteps: 33,
        runUntilDone: false,
        planFirst: false,
        autoRetryEnabled: false,
        autoRetryAttempts: 8,
        autoRetryDelay: 20,
        deviceCommandsEnabled: true,
        languageCode: 'id',
        themeMode: ThemeModeSetting.light,
      );
      final AppSettings decoded = AppSettings.fromJson(original.toJson());

      expect(decoded.opencodeModel, original.opencodeModel);
      expect(decoded.agentMode, original.agentMode);
      expect(decoded.maxSteps, original.maxSteps);
      expect(decoded.runUntilDone, original.runUntilDone);
      expect(decoded.planFirst, original.planFirst);
      expect(decoded.autoRetryEnabled, original.autoRetryEnabled);
      expect(decoded.autoRetryAttempts, original.autoRetryAttempts);
      expect(decoded.autoRetryDelay, original.autoRetryDelay);
      expect(decoded.deviceCommandsEnabled, original.deviceCommandsEnabled);
      expect(decoded.languageCode, original.languageCode);
      expect(decoded.themeMode, original.themeMode);
    });

    test('fromJson degrades missing fields to defaults', () {
      final AppSettings decoded = AppSettings.fromJson(<String, dynamic>{});
      expect(decoded.opencodeModel, '');
      expect(decoded.agentMode, isTrue);
      expect(decoded.maxSteps, defaultMaxSteps);
      expect(decoded.themeMode, ThemeModeSetting.dark);
      expect(decoded.languageCode, 'en');
    });

    test('legacy migration: {"model":"..."} → opencodeModel', () {
      // Pre-OAgents (ZAgents) installs stored the active model under `model`.
      final AppSettings migrated = AppSettings.fromJson(<String, dynamic>{
        'model': 'zai/glm-4.6',
      });
      expect(migrated.opencodeModel, 'zai/glm-4.6');
    });

    test('opencodeModel in JSON wins over a stale legacy `model`', () {
      final AppSettings migrated = AppSettings.fromJson(<String, dynamic>{
        'opencodeModel': 'opencode/glm-4.6',
        'model': 'legacy-model',
      });
      expect(migrated.opencodeModel, 'opencode/glm-4.6');
    });

    test('legacy apiKey/baseUrl/engine/presets in JSON are dropped', () {
      // A real legacy settings blob may still carry the old keys; fromJson
      // must not resurrect them and must not crash.
      final AppSettings migrated = AppSettings.fromJson(<String, dynamic>{
        'apiKey': 'sk-legacy',
        'baseUrl': 'https://old.example/v1',
        'engine': 'openai',
        'presets': <dynamic>[],
        'model': 'legacy-model',
      });
      expect(migrated.opencodeModel, 'legacy-model');
      // The toJson of the migrated settings carries NONE of the legacy keys.
      final Map<String, dynamic> json = migrated.toJson();
      expect(json.containsKey('apiKey'), isFalse);
      expect(json.containsKey('baseUrl'), isFalse);
      expect(json.containsKey('engine'), isFalse);
      expect(json.containsKey('presets'), isFalse);
    });
  });

  group('clampMaxSteps', () {
    test('clamps into 1..100 and parses strings', () {
      expect(clampMaxSteps(0), minMaxSteps);
      expect(clampMaxSteps(-5), minMaxSteps);
      expect(clampMaxSteps(1), 1);
      expect(clampMaxSteps(42), 42);
      expect(clampMaxSteps(100), maxMaxSteps);
      expect(clampMaxSteps(9999), maxMaxSteps);
      expect(clampMaxSteps('77'), 77);
      expect(clampMaxSteps('abc'), minMaxSteps);
    });
  });

  group('clampAutoRetryAttempts', () {
    test('clamps into 1..10', () {
      expect(clampAutoRetryAttempts(0), minAutoRetryAttempts);
      expect(clampAutoRetryAttempts(-1), minAutoRetryAttempts);
      expect(clampAutoRetryAttempts(1), 1);
      expect(clampAutoRetryAttempts(5), 5);
      expect(clampAutoRetryAttempts(10), maxAutoRetryAttempts);
      expect(clampAutoRetryAttempts(99), maxAutoRetryAttempts);
      expect(clampAutoRetryAttempts('4'), 4);
      expect(clampAutoRetryAttempts('nope'), minAutoRetryAttempts);
    });
  });

  group('clampAutoRetryDelay', () {
    test('clamps into 0..60', () {
      expect(clampAutoRetryDelay(-1), minAutoRetryDelay);
      expect(clampAutoRetryDelay(0), 0);
      expect(clampAutoRetryDelay(30), 30);
      expect(clampAutoRetryDelay(60), maxAutoRetryDelay);
      expect(clampAutoRetryDelay(999), maxAutoRetryDelay);
      expect(clampAutoRetryDelay('15'), 15);
      expect(clampAutoRetryDelay('bad'), minAutoRetryDelay);
    });
  });
}
