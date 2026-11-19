// Unit tests for [PrefsSettingsRepository] and [MemorySettingsRepository]
// against the NEW [AppSettings] (opencode-only schema: no apiKey, no baseUrl,
// no engine, no presets, no SecretBox — plain SharedPreferences JSON).
//
// Covers:
//  * MemorySettingsRepository: save/load round-trips opencodeModel + behavior.
//  * PrefsSettingsRepository: defaults when empty, persist + read-back of
//    opencodeModel, corrupted-JSON fallback to defaults, and the legacy
//    `model` → `opencodeModel` migration on load.
//  * Compile-time guarantee that AppSettings has NO apiKey/authToken field
//    (the suite never references them; `copyWith` only takes `opencodeModel`).
//
// Plain `test()` bodies. SharedPreferences is faked via
// `SharedPreferences.setMockInitialValues`.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oagents/models/models.dart';
import 'package:oagents/services/settings_repository.dart';

const String _settingsKey = 'oagents.settings.v1';

void main() {
  group('MemorySettingsRepository', () {
    test('save/load round-trips opencodeModel and behavior fields', () async {
      final MemorySettingsRepository repo = MemorySettingsRepository();
      // load() on a fresh repo yields defaults.
      final AppSettings defaults = repo.load();
      expect(defaults.opencodeModel, '');
      expect(defaults.agentMode, isTrue);
      expect(defaults.runUntilDone, isTrue);

      final AppSettings saved = AppSettings().copyWith(
        opencodeModel: 'opencode/glm-4.6',
        agentMode: false,
        maxSteps: 12,
        autoRetryEnabled: false,
        languageCode: 'id',
      );
      await repo.save(saved);

      final AppSettings loaded = repo.load();
      expect(loaded.opencodeModel, 'opencode/glm-4.6');
      expect(loaded.agentMode, isFalse);
      expect(loaded.maxSteps, 12);
      expect(loaded.autoRetryEnabled, isFalse);
      expect(loaded.languageCode, 'id');
    });

    test('persists independently of the default instance', () async {
      final MemorySettingsRepository a = MemorySettingsRepository();
      await a.save(AppSettings().copyWith(opencodeModel: 'm-a'));
      final MemorySettingsRepository b = MemorySettingsRepository();
      expect(b.load().opencodeModel, '');
      expect(a.load().opencodeModel, 'm-a');
    });
  });

  group('PrefsSettingsRepository', () {
    test('load returns defaults when the store is empty', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final PrefsSettingsRepository repo = PrefsSettingsRepository(prefs);

      final AppSettings loaded = repo.load();
      expect(loaded.opencodeModel, '');
      expect(loaded.agentMode, isTrue);
      expect(loaded.maxSteps, defaultMaxSteps);
      expect(loaded.themeMode, ThemeModeSetting.dark);
      expect(loaded.languageCode, 'en');
    });

    test('save persists opencodeModel and load reads it back', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final PrefsSettingsRepository repo = PrefsSettingsRepository(prefs);

      await repo.save(
        AppSettings().copyWith(
          opencodeModel: 'opencode/claude-sonnet-4.5',
          runUntilDone: false,
          autoRetryAttempts: 7,
        ),
      );
      expect(repo.lastSettingsWriteError, isNull);

      // The persisted JSON carries opencodeModel (and no legacy auth fields).
      final Map<String, dynamic> json =
          jsonDecode(prefs.getString(_settingsKey)!) as Map<String, dynamic>;
      expect(json['opencodeModel'], 'opencode/claude-sonnet-4.5');
      expect(json.containsKey('apiKey'), isFalse);
      expect(json.containsKey('authToken'), isFalse);
      expect(json.containsKey('baseUrl'), isFalse);

      // A fresh repo over the same store reads the value back.
      final PrefsSettingsRepository reopened = PrefsSettingsRepository(prefs);
      final AppSettings loaded = reopened.load();
      expect(loaded.opencodeModel, 'opencode/claude-sonnet-4.5');
      expect(loaded.runUntilDone, isFalse);
      expect(loaded.autoRetryAttempts, 7);
    });

    test('corrupted JSON falls back to defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _settingsKey: '{not json!!',
      });
      final prefs = await SharedPreferences.getInstance();
      final PrefsSettingsRepository repo = PrefsSettingsRepository(prefs);

      final AppSettings loaded = repo.load();
      expect(loaded.opencodeModel, '');
      expect(loaded.agentMode, isTrue);
      expect(loaded.maxSteps, defaultMaxSteps);
    });

    test('create() builds a prefs-backed repo with no secretBox param',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final PrefsSettingsRepository repo =
          await PrefsSettingsRepository.create();
      expect(repo.load().opencodeModel, '');
      await repo.save(AppSettings().copyWith(opencodeModel: 'created'));
      expect(repo.load().opencodeModel, 'created');
    });

    test('legacy migration: fromJson({"model":"legacy-model"}) yields '
        'opencodeModel == legacy-model', () {
      // Simulate a pre-OAgents (ZAgents) install: the legacy schema stored the
      // active model under `model`. AppSettings.fromJson carries it forward as
      // opencodeModel so an upgrading user keeps their last-chosen model id.
      final AppSettings migrated = AppSettings.fromJson(<String, dynamic>{
        'model': 'legacy-model',
      });
      expect(migrated.opencodeModel, 'legacy-model');
    });

    test('opencodeModel in JSON wins over a stale legacy `model`', () {
      final AppSettings migrated = AppSettings.fromJson(<String, dynamic>{
        'opencodeModel': 'opencode/glm-4.6',
        'model': 'legacy-model',
      });
      expect(migrated.opencodeModel, 'opencode/glm-4.6');
    });
  });
}
