import 'dart:async';

import 'package:flutter/services.dart';

/// Fixed localhost endpoint the embedded opencode CLI listens on.
///
/// The opencode binary is bundled inside the APK and launched on-device by
/// the native [OpencodeRuntimeBridge] (Kotlin, see
/// `android/app/src/main/kotlin/.../OpencodeRuntimeBridge.kt`). It binds to
/// this loopback port inside the app sandbox, so it is unreachable from any
/// other app or from the network — no auth is needed on this hop, and no
/// server URL is user-configurable. This is the deliberate difference from
/// the official opencode mobile app (a remote controller): here opencode
/// runs IN this app's process.
const String embeddedOpencodeUrl = 'http://127.0.0.1:4096';
const int embeddedOpencodePort = 4096;

/// Lifecycle state of the embedded opencode runtime, mirrored from the
/// native bridge over the status [EventChannel]. Drives the status badge in
/// Settings → opencode and gates whether chat sends are allowed.
enum OpencodeRuntimeState {
  /// Native bridge has not reported yet (boot window).
  unknown,

  /// First launch: extracting the bundled opencode bundle + NodeJS Mobile
  /// libs from APK assets to private storage. Subsequent launches skip this
  /// unless the bundled version changed.
  extracting,

  /// opencode process spawned, waiting for `GET /health` to answer on
  /// [embeddedOpencodeUrl].
  starting,

  /// opencode is up and serving on [embeddedOpencodeUrl]; chat is allowed.
  running,

  /// opencode process is not running (user stopped it, or the app was
  /// backgrounded and the foreground service was killed).
  stopped,

  /// opencode failed to start (extraction error, libnode load failure,
  /// port conflict, ...). The native bridge surfaces a human-readable
  /// [OpencodeRuntimeStatus.message].
  failed,
}

class OpencodeRuntimeStatus {
  const OpencodeRuntimeStatus({
    required this.state,
    this.version = '',
    this.message = '',
    this.bundledRevision = '',
  });

  final OpencodeRuntimeState state;
  final String version;
  final String message;
  final String bundledRevision;

  bool get isReady => state == OpencodeRuntimeState.running;

  factory OpencodeRuntimeStatus.fromMap(Map<dynamic, dynamic> map) {
    final String? stateName = map['state']?.toString();
    OpencodeRuntimeState parsed = OpencodeRuntimeState.unknown;
    for (final s in OpencodeRuntimeState.values) {
      if (s.name == stateName) {
        parsed = s;
        break;
      }
    }
    return OpencodeRuntimeStatus(
      state: parsed,
      version: map['version']?.toString() ?? '',
      message: map['message']?.toString() ?? '',
      bundledRevision: map['bundledRevision']?.toString() ?? '',
    );
  }

  static const OpencodeRuntimeStatus initial = OpencodeRuntimeStatus(
    state: OpencodeRuntimeState.unknown,
  );

  @override
  String toString() =>
      'OpencodeRuntimeStatus(state=${state.name}, version=$version)';
}

/// Handles the embedded opencode CLI lifecycle through a platform channel
/// to the native Kotlin bridge.
///
/// The native side (`OpencodeRuntimeBridge`) does the heavy lifting:
/// extracting the bundled `opencode.bundle.js` + per-ABI `libnode.so` from
/// APK assets to the app's private data dir, spawning NodeJS Mobile with
/// the opencode bundle running `opencode serve --port 4096`, and keeping it
/// alive via an Android foreground service. This Dart class is a thin,
/// testable facade: every method is a one-line channel call so a fake
/// channel in tests fully controls the lifecycle.
class OpencodeRuntimeBridge {
  OpencodeRuntimeBridge()
    : _method = const MethodChannel('com.secretarrow.oagents/opencode'),
      _events = const EventChannel('com.secretarrow.oagents/opencode/status');

  final MethodChannel _method;
  final EventChannel _events;

  Stream<OpencodeRuntimeStatus>? _statusStream;
  OpencodeRuntimeStatus _lastStatus = OpencodeRuntimeStatus.initial;

  /// Latest status received over the event channel (or [start] result).
  /// Synchronous so the UI badge renders instantly after a rebuild.
  OpencodeRuntimeStatus get currentStatus => _lastStatus;

  /// Asks the native bridge to bring the embedded opencode up (extract on
  /// first launch, spawn, wait for `/health`). Returns the resulting
  /// status; never throws — a failure comes back as
  /// [OpencodeRuntimeState.failed] with a message.
  Future<OpencodeRuntimeStatus> start() async {
    try {
      final result = await _method.invokeMethod<Map>('start');
      _lastStatus = _coerce(result);
      return _lastStatus;
    } on PlatformException catch (e) {
      _lastStatus = OpencodeRuntimeStatus(
        state: OpencodeRuntimeState.failed,
        message: e.message ?? e.code,
      );
      return _lastStatus;
    } catch (e) {
      _lastStatus = OpencodeRuntimeStatus(
        state: OpencodeRuntimeState.failed,
        message: e.toString(),
      );
      return _lastStatus;
    }
  }

  /// Stops the embedded opencode process (the foreground service is taken
  /// down with it). Safe to call when already stopped.
  Future<void> stop() async {
    try {
      await _method.invokeMethod<void>('stop');
      _lastStatus = const OpencodeRuntimeStatus(
        state: OpencodeRuntimeState.stopped,
      );
    } catch (_) {
      // Best-effort; status stream will reconcile.
    }
  }

  /// Polls the current status without changing the runtime state.
  Future<OpencodeRuntimeStatus> status() async {
    try {
      final result = await _method.invokeMethod<Map>('status');
      _lastStatus = _coerce(result);
      return _lastStatus;
    } catch (_) {
      return _lastStatus;
    }
  }

  /// Returns the opencode CLI version string reported by the native bridge
  /// (read from the bundled bundle's package.json at extraction time).
  Future<String> version() async {
    try {
      final v = await _method.invokeMethod<String>('version');
      return v ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Hot, broadcast stream of status transitions emitted by the native
  /// bridge. Re-used across listeners so the Settings screen, the chat
  /// gate and the cron scheduler all see the same events.
  Stream<OpencodeRuntimeStatus> statusStream() {
    _statusStream ??= _events
        .receiveBroadcastStream()
        .map(_coerce)
        .asBroadcastStream()
        .handleError((_) {});
    return _statusStream!;
  }

  /// Brings the runtime to [OpencodeRuntimeState.running] and resolves; if
  /// it is already running, returns immediately. Used at app boot
  /// (main.dart) and before the first chat send of a session so the user
  /// never sees a "connection refused" from a not-yet-ready opencode.
  Future<OpencodeRuntimeStatus> ensureReady({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_lastStatus.isReady) return _lastStatus;
    final OpencodeRuntimeStatus s = await start();
    if (s.isReady) return s;
    // Wait for the status stream to flip to running (the native bridge
    // emits starting → running once `/health` answers).
    final completer = Completer<OpencodeRuntimeStatus>();
    final sub = statusStream().listen((event) {
      _lastStatus = event;
      if (event.isReady && !completer.isCompleted) {
        completer.complete(event);
      } else if (event.state == OpencodeRuntimeState.failed &&
          !completer.isCompleted) {
        completer.complete(event);
      }
    });
    try {
      return await completer.future.timeout(timeout, onTimeout: () {
        return const OpencodeRuntimeStatus(
          state: OpencodeRuntimeState.failed,
          message: 'opencode did not become ready within 30s',
        );
      });
    } finally {
      await sub.cancel();
    }
  }

  OpencodeRuntimeStatus _coerce(Object? raw) {
    if (raw is Map) return OpencodeRuntimeStatus.fromMap(raw);
    return OpencodeRuntimeStatus.initial;
  }
}

/// Fake bridge for unit/widget tests: no platform channel, fully
/// programmable. Lets the chat gate, cron scheduler and settings UI be
/// tested without a real opencode runtime.
class FakeOpencodeRuntimeBridge extends OpencodeRuntimeBridge {
  FakeOpencodeRuntimeBridge({
    OpencodeRuntimeStatus initial = const OpencodeRuntimeStatus(
      state: OpencodeRuntimeState.running,
      version: 'test-opencode-0.0.0',
    ),
  }) : _status = initial {
    _controller = StreamController<OpencodeRuntimeStatus>.broadcast();
    _controller.add(initial);
  }

  OpencodeRuntimeStatus _status;
  late final StreamController<OpencodeRuntimeStatus> _controller;

  @override
  OpencodeRuntimeStatus get currentStatus => _status;

  @override
  Future<OpencodeRuntimeStatus> start() async {
    _status = const OpencodeRuntimeStatus(
      state: OpencodeRuntimeState.running,
      version: 'test-opencode-0.0.0',
    );
    _controller.add(_status);
    return _status;
  }

  @override
  Future<void> stop() async {
    _status = const OpencodeRuntimeStatus(state: OpencodeRuntimeState.stopped);
    _controller.add(_status);
  }

  @override
  Future<OpencodeRuntimeStatus> status() async => _status;

  @override
  Future<String> version() async => _status.version;

  @override
  Stream<OpencodeRuntimeStatus> statusStream() => _controller.stream;

  @override
  Future<OpencodeRuntimeStatus> ensureReady({Duration? timeout}) async =>
      _status;

  void emit(OpencodeRuntimeStatus status) {
    _status = status;
    _controller.add(status);
  }

  void dispose() {
    _controller.close();
  }
}
