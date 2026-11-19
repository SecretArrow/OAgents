import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Abstraction over persistent settings storage.
///
/// OAgents stores NO credentials in settings: the opencode CLI runs
/// embedded inside the app on a fixed localhost endpoint, so the
/// OAgents ↔ opencode hop needs no auth. opencode's OWN provider auth
/// (OpenAI/Anthropic/... API keys) is opencode's business — it lives in
/// opencode's own auth file inside the app's private storage, managed by
/// opencode's standard auth flow, never inside [AppSettings]. So this
/// repository is a plain JSON blob in SharedPreferences: no SecretBox,
/// no Keystore indirection, no plaintext-stripping migration.
abstract class SettingsRepository {
  AppSettings load();
  Future<void> save(AppSettings settings);
}

/// SharedPreferences-backed repository used in production.
///
/// The settings JSON is persisted atomically via SharedPreferences. A
/// failed write is recorded in [lastSettingsWriteError] but never thrown —
/// the in-memory [SettingsController] keeps the user's edit either way, so
/// a transient disk failure does not silently revert a toggle the user
/// just tapped (the next successful save catches up).
class PrefsSettingsRepository implements SettingsRepository {
  PrefsSettingsRepository(this._prefs);

  final SharedPreferences _prefs;

  static const String _key = 'oagents.settings.v1';

  /// Description of the most recent failed prefs write, or null. Cleared
  /// at the start of every [save].
  String? lastSettingsWriteError;

  static Future<PrefsSettingsRepository> create() async {
    final prefs = await SharedPreferences.getInstance();
    return PrefsSettingsRepository(prefs);
  }

  @override
  AppSettings load() {
    final String? raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return AppSettings();
    final Map<String, dynamic>? decoded = _decode(raw);
    if (decoded == null) {
      // Corrupted settings: fall back to defaults.
      return AppSettings();
    }
    return AppSettings.fromJson(decoded);
  }

  @override
  Future<void> save(AppSettings settings) async {
    final Map<String, dynamic> json = settings.toJson();
    lastSettingsWriteError = null;
    try {
      await _prefs.setString(_key, jsonEncode(json));
    } catch (error) {
      lastSettingsWriteError = 'Settings write failed for $_key: $error';
    }
  }

  Map<String, dynamic>? _decode(String raw) {
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Corrupted settings: fall back to defaults.
    }
    return null;
  }
}

/// In-memory repository for unit and widget tests.
class MemorySettingsRepository implements SettingsRepository {
  MemorySettingsRepository([AppSettings? initial])
    : _settings = initial ?? AppSettings();

  AppSettings _settings;

  @override
  AppSettings load() => _settings;

  @override
  Future<void> save(AppSettings settings) async => _settings = settings;
}
