import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../services/opencode_client.dart';
import '../../services/opencode_runtime.dart';
import '../../services/toolbox_manifest.dart';

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
  ToolboxManifest? _manifest;

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
    unawaited(_loadManifest());
  }

  Future<void> _loadManifest() async {
    final m = await ToolboxManifestLoader.instance.load();
    if (!mounted) return;
    setState(() => _manifest = m);
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
          const SizedBox(height: 16),
          _ToolboxCard(manifest: _manifest, theme: theme),
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

/// Shows the bundled Node toolbox: the opencode/toolbox revision, the Node
/// runtime path, and the pre-installed crypto / dev / browser modules the
/// embedded runtime can `require()`. Reads the CI-produced manifest via
/// [ToolboxManifestLoader]; when the manifest is absent (build without the
/// CI bundle staged), it shows an actionable hint instead of an empty list.
class _ToolboxCard extends StatelessWidget {
  const _ToolboxCard({required this.manifest, required this.theme});

  final ToolboxManifest? manifest;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    if (manifest == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              const SizedBox(
                size: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text('Loading toolbox manifest…',
                  style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      );
    }
    final m = manifest!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.extension_rounded,
                    size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Embedded Node toolbox',
                    style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            if (!m.isPresent) ...<Widget>[
              Text(
                'No toolbox bundled in this build. The CI bundle-opencode job '
                'produces toolbox.tar.gz (node + npm/npx + opencode + '
                'crypto/dev modules + agent-browser + playwright-core); a '
                'release build stages it into assets/toolbox/.',
                style: theme.textTheme.bodyMedium,
              ),
            ] else ...<Widget>[
              _metaRow('revision', m.version.isEmpty ? '—' : m.version),
              _metaRow('node runtime', m.nodeRuntime),
              _metaRow('modules', '${m.totalModules} packages'),
              const SizedBox(height: 12),
              _category('Crypto / web3', m.crypto),
              const SizedBox(height: 10),
              _category('Developer tooling', m.dev),
              const SizedBox(height: 10),
              _category('Browser', m.browser),
              const SizedBox(height: 10),
              Text(
                'Browser automation on-device uses the app’s embedded WebView '
                '(flutter_inappwebview), not Playwright’s Chromium (glibc-only, '
                'not shipped). `require(\'playwright\')` resolves to '
                'playwright-core for API compatibility; actual page work is '
                'driven by the agent’s browser_* tools.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metaRow(String k, String v) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 110,
          child: Text(k,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: Text(v, style: theme.textTheme.bodySmall),
        ),
      ],
    ),
  );

  Widget _category(String label, List<BundledModule> modules) {
    if (modules.isEmpty) {
      return Text('$label: none bundled',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline));
    }
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text('$label:',
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        for (final mod in modules)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              mod.version.isEmpty ? mod.name : '${mod.name}@${mod.version}',
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 10.5,
              ),
            ),
          ),
      ],
    );
  }
}
