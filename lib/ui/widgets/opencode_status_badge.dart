import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../services/opencode_runtime.dart';
import '../screens/opencode_setup_screen.dart';

/// v1.0.6 — always-visible opencode runtime indicator for the main app bar.
///
/// Subscribes to the runtime status [EventChannel] (through
/// [OpencodeRuntimeBridge.statusStream]) and renders one compact badge that
/// answers "is opencode up?" at a glance:
///
///   ● opencode        green solid dot — running, version shown
///   ◐ opencode …      amber pulsing dot — booting (extracting/starting),
///                     animated so a stuck boot is visible as "still
///                     loading", not a frozen UI
///   ● opencode ✕      red dot — failed (message on the setup screen)
///   ○ opencode off    hollow outline dot — stopped/unknown
///
/// Tapping it opens the opencode setup screen, where the full status card,
/// failure message, version/bundle revision and the start/stop controls
/// live. No SnackBar/Toast anywhere — status is state, not a notification.
// ConsumerStatefulWidget (not StatefulWidget): the state class reads the
// runtime provider in initState, which requires Riverpod's `ref` on both
// sides of the pair.
class OpencodeStatusBadge extends ConsumerStatefulWidget {
  const OpencodeStatusBadge({super.key});

  @override
  ConsumerState<OpencodeStatusBadge> createState() =>
      _OpencodeStatusBadgeState();
}

class _OpencodeStatusBadgeState extends ConsumerState<OpencodeStatusBadge> {
  StreamSubscription<OpencodeRuntimeStatus>? _sub;
  OpencodeRuntimeStatus _status = OpencodeRuntimeStatus.initial;

  @override
  void initState() {
    super.initState();
    final bridge = ref.read(opencodeRuntimeProvider);
    // Seed synchronously so the badge paints a real state on the very
    // first frame instead of flashing "unknown" for one build.
    _status = bridge.currentStatus;
    _sub = bridge.statusStream().listen((s) {
      if (!mounted) return;
      setState(() => _status = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (_status.state) {
      OpencodeRuntimeState.running => Colors.green,
      OpencodeRuntimeState.starting ||
      OpencodeRuntimeState.extracting => Colors.amber.shade700,
      OpencodeRuntimeState.failed => theme.colorScheme.error,
      _ => theme.colorScheme.outline,
    };
    final bool loading =
        _status.state == OpencodeRuntimeState.starting ||
        _status.state == OpencodeRuntimeState.extracting;
    return Tooltip(
      message: _tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: TextButton(
        // Compact hit target in the app bar; the whole badge is tappable.
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: color,
        ),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const OpencodeSetupScreen()),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 14,
              height: 14,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _status.state == OpencodeRuntimeState.running
                      ? color
                      : _status.state == OpencodeRuntimeState.stopped ||
                            _status.state == OpencodeRuntimeState.unknown
                      ? Colors.transparent
                      : color.withValues(alpha: 0.45),
                  border: Border.fromBorderSide(
                    BorderSide(color: color, width: 2),
                  ),
                ),
                // Pulsing while the runtime boots: extraction (first run,
                // ~558MB) and health-wait can take seconds to a minute;
                // a static dot there reads as "done/hung".
                child: loading
                    ? _PulsingDot(color: color)
                    : const SizedBox.shrink(),
              ),
            ),
            const SizedBox(width: 7),
            Text(
              _label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _label => switch (_status.state) {
    OpencodeRuntimeState.running =>
      _status.version.isNotEmpty ? 'opencode ${_status.version}' : 'opencode',
    OpencodeRuntimeState.extracting => 'opencode …',
    OpencodeRuntimeState.starting => 'opencode …',
    OpencodeRuntimeState.failed => 'opencode ✕',
    OpencodeRuntimeState.stopped => 'opencode off',
    OpencodeRuntimeState.unknown => 'opencode …',
  };

  String get _tooltip => switch (_status.state) {
    OpencodeRuntimeState.running =>
      _status.version.isNotEmpty
          ? 'opencode is running (${_status.version})'
          : 'opencode is running',
    OpencodeRuntimeState.extracting =>
      'opencode is unpacking its embedded toolbox (first run only)',
    OpencodeRuntimeState.starting =>
      'opencode is booting and will be ready shortly',
    OpencodeRuntimeState.failed =>
      _status.message.isNotEmpty
          ? 'opencode failed to start: ${_status.message}'
          : 'opencode failed to start',
    OpencodeRuntimeState.stopped => 'opencode is stopped — tap to start',
    OpencodeRuntimeState.unknown =>
      'opencode status unknown — waiting for the runtime bridge',
  };
}

/// An amber dot that fades in/out forever while the runtime is booting.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});

  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
        child: const SizedBox.expand(),
      ),
    );
  }
}
