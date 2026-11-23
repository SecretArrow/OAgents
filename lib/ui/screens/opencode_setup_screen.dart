import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../models/models.dart';
import '../../services/opencode_client.dart';
import '../../services/opencode_runtime.dart';
import '../../services/toolbox_manifest.dart';
import 'provider_credentials_screen.dart';

/// Replaces the old Providers + Ollama Manage screens.
///
/// OAgents has exactly one AI backend: the opencode CLI embedded inside the
/// app. This screen is the single place where the user sees that backend's
/// state and picks which model it should route to. opencode runs locally
/// on [embeddedOpencodeUrl]; its OWN provider auth (OpenAI / Anthropic /
/// ... API keys) is configured in-app through [ProviderCredentialsScreen],
/// reachable from the "Provider keys" card below — no terminal needed.
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
  List<OpencodeCredential> _credentials = const <OpencodeCredential>[];

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
    unawaited(_loadCredentials());
  }

  /// Credential summary for the "Provider keys" card. Loaded whenever the
  /// screen appears AND after the user returns from the credentials
  /// screen, so the "N keys" row never goes stale.
  Future<void> _loadCredentials() async {
    try {
      final credentials = await ref
          .read(opencodeClientProvider)
          .listCredentials(serverUrl: embeddedOpencodeUrl);
      if (!mounted) return;
      setState(() => _credentials = credentials);
    } catch (_) {
      // The summary row degrades to "No keys — add one"; the credentials
      // screen owns the real error/retry surface.
    }
  }

  /// Opens the credential manager. On return, the model catalog and the
  /// key summary are re-fetched — the server swaps model availability
  /// with every credential create/activate/delete (per-contract: no
  /// keys → 10 models, one openai key → 82).
  Future<void> _openCredentials() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ProviderCredentialsScreen(),
      ),
    );
    if (!mounted) return;
    await _loadCredentials();
    await _loadModels();
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
      final models = await ref
          .read(opencodeClientProvider)
          .listModels(serverUrl: embeddedOpencodeUrl);
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
      setState(
        () => _status = const OpencodeRuntimeStatus(
          state: OpencodeRuntimeState.starting,
        ),
      );
      await bridge.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
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
                    .update(
                      ref.read(settingsProvider).copyWith(opencodeModel: id),
                    );
              },
              theme: theme,
            ),
          const SizedBox(height: 8),
          Text(
            'Empty = use opencode’s configured default model.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          _ProviderKeysCard(
            credentials: _credentials,
            onManage: _openCredentials,
            theme: theme,
          ),
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
            Row(
              children: <Widget>[
                Icon(Icons.circle, color: color, size: 12),
                const SizedBox(width: 8),
                Text(status.state.name, style: theme.textTheme.titleMedium),
              ],
            ),
            if (status.version.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                'opencode ${status.version}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (status.bundledRevision.isNotEmpty) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                'bundle ${status.bundledRevision}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (status.message.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                status.message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                FilledButton(
                  onPressed: onToggle,
                  child: Text(status.isReady ? 'Stop' : 'Start'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: status.isReady ? onRefreshModels : null,
                  child: const Text('Refresh models'),
                ),
              ],
            ),
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
      onChanged: (String? v) {
        if (v != null) onChanged(v);
      },
    );
    if (models.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          dropdown,
          const SizedBox(height: 4),
          Text(
            'No models yet — add a provider API key under Provider keys, '
            'then refresh.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    }
    return dropdown;
  }
}

/// "Provider keys" — the in-app provider credential summary. Replaces the
/// old _AuthNote, which told users to run `opencode auth login` from a
/// terminal that does not exist in this app; opencode's credential API is
/// now managed by [ProviderCredentialsScreen] instead. The card shows a
/// one-line summary ("N keys, M active providers" / "No keys — add one")
/// with a Manage button that pushes that screen; on return the caller
/// re-fetches the model catalog (the server swaps model availability with
/// every credential change).
class _ProviderKeysCard extends StatelessWidget {
  const _ProviderKeysCard({
    required this.credentials,
    required this.onManage,
    required this.theme,
  });

  final List<OpencodeCredential> credentials;
  final VoidCallback onManage;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final int activeProviders = <String>{
      for (final c in credentials)
        if (c.active) c.integrationID,
    }.length;
    final int keyCount = credentials.length;
    final String summary = keyCount == 0
        ? 'No keys — add one'
        : '$keyCount ${keyCount == 1 ? 'key' : 'keys'}, '
              '$activeProviders active '
              '${activeProviders == 1 ? 'provider' : 'providers'}';
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onManage,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.vpn_key_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Provider keys',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: theme.colorScheme.outline,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(summary, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              Text(
                'opencode talks to OpenAI, Anthropic, Google, OpenRouter and '
                'friends with keys stored by the embedded server itself — '
                'OAgents never keeps them. Add or activate a key to unlock '
                'that provider’s models.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  OutlinedButton(
                    onPressed: onManage,
                    child: const Text('Manage'),
                  ),
                ],
              ),
            ],
          ),
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
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(
                'Loading toolbox manifest…',
                style: theme.textTheme.bodyMedium,
              ),
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
                Icon(
                  Icons.extension_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Embedded Node toolbox',
                  style: theme.textTheme.titleSmall,
                ),
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
          child: Text(
            k,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(child: Text(v, style: theme.textTheme.bodySmall)),
      ],
    ),
  );

  Widget _category(String label, List<BundledModule> modules) {
    if (modules.isEmpty) {
      return Text(
        '$label: none bundled',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          '$label:',
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
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
