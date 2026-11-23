import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../services/opencode_client.dart';
import '../../services/opencode_runtime.dart';
import '../widgets/app_message.dart';

/// "Provider keys" — the in-app replacement for `opencode auth login`.
///
/// OAgents has no terminal, so the old "run opencode auth login from the
/// app's opencode terminal" note in [OpencodeSetupScreen] could never be
/// followed. The embedded opencode server exposes its own credential API
/// (`/api/credential`, proxied verbatim by the compat adapter on
/// [embeddedOpencodeUrl]) and this screen is the one place the user
/// manages provider API keys with it: list, add, activate, delete — no
/// terminal, no app storage. Keys live only in opencode's own sqlite
/// store, exactly where the chat path reads them from.
///
/// Activation is EXCLUSIVE per provider on the server side: tapping a key
/// makes it THE active key for its provider and flips every other key of
/// that provider off. The tile tap and the confirm dialog both say so.
class ProviderCredentialsScreen extends ConsumerStatefulWidget {
  const ProviderCredentialsScreen({super.key});

  @override
  ConsumerState<ProviderCredentialsScreen> createState() =>
      _ProviderCredentialsScreenState();
}

/// Providers offered in the "Add key" dropdown. The server accepts any
/// `integrationID` string, but the model catalog only reacts to
/// recognized ids, so the dropdown sticks to the six that matter.
const List<String> kCredentialProviders = <String>[
  'openai',
  'anthropic',
  'google',
  'openrouter',
  'ollama',
  'lmstudio',
];

class _ProviderCredentialsScreenState
    extends ConsumerState<ProviderCredentialsScreen> {
  List<OpencodeCredential> _credentials = const <OpencodeCredential>[];
  bool _loading = true;
  String? _error;
  bool _busy = false;

  String _provider = 'openai';
  bool _obscureKey = true;
  late final TextEditingController _apiKey;
  late final TextEditingController _label;

  @override
  void initState() {
    super.initState();
    _apiKey = TextEditingController();
    _label = TextEditingController();
    unawaited(_load());
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<OpencodeCredential> credentials = await ref
          .read(opencodeClientProvider)
          .listCredentials(serverUrl: embeddedOpencodeUrl);
      if (!mounted) return;
      setState(() {
        _credentials = credentials;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _add() async {
    if (_busy) return;
    final String apiKey = _apiKey.text.trim();
    if (apiKey.isEmpty) {
      showAppMessage(context, 'Enter an API key first.', error: true);
      return;
    }
    final String label = _label.text.trim().isEmpty
        ? 'default'
        : _label.text.trim();
    setState(() => _busy = true);
    try {
      await ref
          .read(opencodeClientProvider)
          .createCredential(
            serverUrl: embeddedOpencodeUrl,
            integrationID: _provider,
            apiKey: apiKey,
            label: label,
            activate: true,
          );
      _apiKey.clear();
      _label.clear();
      if (!mounted) return;
      showAppMessage(context, '$_provider key saved and activated.');
      await _load();
    } catch (e) {
      if (!mounted) return;
      showAppMessage(context, '$e', error: true);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _activate(OpencodeCredential credential) async {
    if (_busy || credential.active) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Activate this key?'),
        content: Text(
          'Only one key per provider is active — activating the '
          '${credential.integrationID} key “${credential.label}” '
          'deactivates every other ${credential.integrationID} key.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Activate'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(opencodeClientProvider)
          .activateCredential(
            serverUrl: embeddedOpencodeUrl,
            id: credential.id,
          );
      await _load();
      if (!mounted) return;
      showAppMessage(
        context,
        '${credential.integrationID} key “${credential.label}” activated.',
      );
    } catch (e) {
      if (!mounted) return;
      showAppMessage(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(OpencodeCredential credential) async {
    if (_busy) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Delete this key?'),
        content: Text(
          'Removes the ${credential.integrationID} key '
          '“${credential.label}” from opencode. This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(opencodeClientProvider)
          .deleteCredential(serverUrl: embeddedOpencodeUrl, id: credential.id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      showAppMessage(context, '$e', error: true);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Widget> listTiles = <Widget>[
      for (final OpencodeCredential c in _credentials)
        _CredentialTile(
          credential: c,
          onActivate: _activate,
          onDelete: _delete,
          theme: theme,
        ),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Provider keys')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: <Widget>[
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            _ErrorCard(error: _error!, onRetry: _load, theme: theme)
          else if (_credentials.isEmpty)
            _EmptyCard(theme: theme)
          else ...<Widget>[...listTiles],
          if (!_loading && _error == null) const SizedBox(height: 24),
          _AddKeyCard(
            provider: _provider,
            onProviderChanged: (String v) => setState(() => _provider = v),
            apiKeyController: _apiKey,
            labelController: _label,
            obscureKey: _obscureKey,
            onToggleObscure: () => setState(() => _obscureKey = !_obscureKey),
            onAdd: _add,
            busy: _busy,
            theme: theme,
          ),
        ],
      ),
    );
  }
}

/// One stored key: provider (integrationID) + label + active badge +
/// delete. Tapping the tile activates the key (with a confirm dialog —
/// activation is exclusive per provider); the delete icon removes it
/// (also with a confirm dialog).
class _CredentialTile extends StatelessWidget {
  const _CredentialTile({
    required this.credential,
    required this.onActivate,
    required this.onDelete,
    required this.theme,
  });

  final OpencodeCredential credential;
  final ValueChanged<OpencodeCredential> onActivate;
  final ValueChanged<OpencodeCredential> onDelete;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: () => onActivate(credential),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      credential.integrationID,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (credential.active) ...<Widget>[
                    Icon(Icons.circle, color: Colors.green, size: 12),
                    const SizedBox(width: 6),
                    Text(
                      'active',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.green,
                      ),
                    ),
                  ] else
                    Text(
                      'inactive',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete key',
                    onPressed: () => onDelete(credential),
                  ),
                ],
              ),
              if (credential.label.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  'label ${credential.label}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (!credential.active) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  'Tap to make this the active ${credential.integrationID} '
                  'key — only one key per provider is active.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// No keys yet — the friendly hint, same shape as _ToolboxCard's
/// "not present" hint in the setup screen.
class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
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
                Text('No provider keys yet', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Add a provider API key to enable chat models. Without a key '
              'opencode only offers its built-in free models; one OpenAI / '
              'Anthropic / Google / OpenRouter key unlocks that provider’s '
              'whole catalog. Keys are stored by the embedded opencode '
              'server itself — OAgents never keeps them.',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// List failed — short error line + Retry (the _loadModels error pattern
/// from the setup screen).
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.error,
    required this.onRetry,
    required this.theme,
  });

  final String error;
  final VoidCallback onRetry;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Could not load provider keys: $error',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// "Add key" form: provider dropdown, obscured API-key field with a
/// visibility toggle, optional label, Add button.
class _AddKeyCard extends StatelessWidget {
  const _AddKeyCard({
    required this.provider,
    required this.onProviderChanged,
    required this.apiKeyController,
    required this.labelController,
    required this.obscureKey,
    required this.onToggleObscure,
    required this.onAdd,
    required this.busy,
    required this.theme,
  });

  final String provider;
  final ValueChanged<String> onProviderChanged;
  final TextEditingController apiKeyController;
  final TextEditingController labelController;
  final bool obscureKey;
  final VoidCallback onToggleObscure;
  final VoidCallback onAdd;
  final bool busy;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.add_circle_outline,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text('Add a key', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'The key is sent to the embedded opencode server and stored '
              'by it (activate = on). Adding a second key for the same '
              'provider keeps both; activating one deactivates the other.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: provider,
              decoration: const InputDecoration(labelText: 'Provider'),
              items: <DropdownMenuItem<String>>[
                for (final String p in kCredentialProviders)
                  DropdownMenuItem<String>(value: p, child: Text(p)),
              ],
              onChanged: (String? v) {
                if (v != null) onProviderChanged(v);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: apiKeyController,
              obscureText: obscureKey,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API key',
                hintText: 'sk-…',
                suffixIcon: IconButton(
                  icon: Icon(
                    obscureKey
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  tooltip: obscureKey ? 'Show key' : 'Hide key',
                  onPressed: onToggleObscure,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: labelController,
              decoration: const InputDecoration(
                labelText: 'Label (optional)',
                hintText: 'default',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : onAdd,
              child: busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Add key'),
            ),
          ],
        ),
      ),
    );
  }
}
