import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../services/opencode_client.dart';
import '../../services/opencode_runtime.dart';

/// Replaces the old Providers + Ollama Manage screens.
///
/// OAgents has exactly one AI backend: the opencode CLI embedded inside the
/// app. This screen is the single place where the user sees that backend's
/// state and picks which model it should route to. There is no provider
/// list, no API-key field and no server URL field here — opencode runs
/// locally on [embeddedOpencodeUrl] and its OWN provider auth (OpenAI /
/// Anthropic / ... API keys) is configured through opencode's standard
/// auth flow, not through this app's settings.
class OpencodeSetupScreen extends ConsumerStatefulWidget {
  const OpencodeSetupScreen({super.key});

  @override
  ConsumerState<OpencodeSetupScreen> createState() =>
      _OpencodeSetupScreenState();
}

class _OpencodeSetupScreenState extends ConsumerState<OpencodeSetupScreen> {
  StreamSubscription<OpencodeRuntimeStatus>? _sub;
  OpencodeRuntimeStatus _status = OpencodeRuntimeStatus.initial;
  List<OpencodeModel> _models = const <OpencodeModel>[];
  bool _loadingModels = false;
  String? _modelsError;

  @override
  void initState() {
    super.initState();
    final bridge = ref.read(opencodeRuntimeProvider);
    _status = bridge.currentStatus;
    _sub = bridge.statusStream().listen((s) {
      if (!mounted) return;
      setState(() => _status = s);
      if (s.isReady && _models.isEmpty) {
        _loadModels();
      }
    });
    if (_status.isReady) _loadModels();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadModels() async {
    if (_loadingModels) return;
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });
    try {
      final models = await ref.read(opencodeClientProvider).listModels(
        serverUrl: embeddedOpencodeUrl,
      );
      if (!mounted) return;
      setState(() {
        _models = models;
        _loadingModels = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _modelsError = e.toString();
        _loadingModels = false;
      });
    }
  }

  Future<void> _toggle() async {
    final bridge = ref.read(opencodeRuntimeProvider);
    if (_status.isReady) {
      await bridge.stop();
    } else {
      setState(() => _status = const OpencodeRuntimeStatus(
        state: OpencodeRuntimeState.starting,
      ));
      await bridge.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final strings = appStringsFor(settings.languageCode);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('opencode')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: <Widget>[
          _StatusCard(
            status: _status,
            onToggle: _toggle,
            onRefreshModels: _loadModels,
            theme: theme,
          ),
          const SizedBox(height: 16),
          Text('Model', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_loadingModels)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_modelsError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Could not load models: $_modelsError',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            )
          else
            _ModelPicker(
              models: _models,
              selected: settings.opencodeModel,
              onChanged: (id) {
                ref
                    .read(settingsProvider.notifier)
                    .update((s) => s.copyWith(opencodeModel: id));
              },
              theme: theme,
            ),
          const SizedBox(height: 8),
          Text(
            'Empty = use opencode’s configured default model.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          _AuthNote(theme: theme, strings: strings),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.onToggle,
    required this.onRefreshModels,
    required this.theme,
  });

  final OpencodeRuntimeStatus status;
  final VoidCallback onToggle;
  final VoidCallback onRefreshModels;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final color = switch (status.state) {
      OpencodeRuntimeState.running => Colors.green,
      OpencodeRuntimeState.starting ||
      OpencodeRuntimeState.extracting => Colors.amber,
      OpencodeRuntimeState.failed => theme.colorScheme.error,
      _ => theme.colorScheme.outline,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(children: <Widget>[
              Icon(Icons.circle, color: color, size: 12),
              const SizedBox(width: 8),
              Text(status.state.name, style: theme.textTheme.titleMedium),
            ]),
            if (status.version.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text('opencode ${status.version}',
                  style: theme.textTheme.bodySmall),
            ],
            if (status.bundledRevision.isNotEmpty) ...<Widget>[
              const SizedBox(height: 2),
              Text('bundle ${status.bundledRevision}',
                  style: theme.textTheme.bodySmall),
            ],
            if (status.message.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(status.message,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Row(children: <Widget>[
              FilledButton(
                onPressed: onToggle,
                child: Text(status.isReady ? 'Stop' : 'Start'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: status.isReady ? onRefreshModels : null,
                child: const Text('Refresh models'),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              'Endpoint: $embeddedOpencodeUrl',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  const _ModelPicker({
    required this.models,
    required this.selected,
    required this.onChanged,
    required this.theme,
  });

  final List<OpencodeModel> models;
  final String selected;
  final ValueChanged<String> onChanged;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final dropdown = DropdownButton<String>(
      value: selected.isEmpty ? null : selected,
      hint: const Text('opencode default'),
      isExpanded: true,
      items: <DropdownMenuItem<String>>[
        const DropdownMenuItem<String>(
          value: '',
          child: Text('opencode default'),
        ),
        for (final m in models)
          DropdownMenuItem<String>(
            value: m.id,
            child: Text(m.name.isEmpty ? m.id : '${m.id} (${m.name})'),
          ),
      ],
      onChanged: onChanged,
    );
    if (models.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          dropdown,
          const SizedBox(height: 4),
          Text(
            'No models advertised by opencode yet — configure opencode’s '
            'provider auth (`opencode auth login`) and refresh.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    }
    return dropdown;
  }
}

class _AuthNote extends StatelessWidget {
  const _AuthNote({required this.theme, required this.strings});
  final ThemeData theme;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(children: <Widget>[
              Icon(Icons.info_outline, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Provider auth', style: theme.textTheme.titleSmall),
            ]),
            const SizedBox(height: 8),
            Text(
              'opencode talks to its own model providers (OpenAI, Anthropic, '
              'etc.) using credentials it manages itself. Run '
              '`opencode auth login` from the app’s opencode terminal once, '
              'then the embedded runtime picks them up automatically. '
              'OAgents never stores these keys.',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
