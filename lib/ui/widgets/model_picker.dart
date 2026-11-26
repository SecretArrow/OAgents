import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../services/opencode_client.dart';
import '../../services/opencode_runtime.dart';
import '../theme.dart';
import 'paged_list.dart';

/// Top-bar chip showing the active model; opens the picker sheet.
///
/// v1.0.8: the chip is PER-CHAT — it shows the displayed chat's model
/// override (set through this same picker, the CLI's /model command) and
/// falls back to the app-wide default when the chat has none. Switching
/// chats updates the chip live through [ChatState.opencodeModel].
class ModelChip extends ConsumerWidget {
  const ModelChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppStrings strings = stringsOf(context);
    final String appDefault = ref.watch(
      settingsProvider.select((s) => s.opencodeModel),
    );
    final String chatModel = ref.watch(
      chatControllerProvider.select((s) => s.opencodeModel),
    );
    final String model = chatModel.isNotEmpty ? chatModel : appDefault;
    final bool ready = ref.watch(
      opencodeRuntimeProvider.select((b) => b.currentStatus.isReady),
    );
    return InkWell(
      key: const Key('model-chip'),
      borderRadius: BorderRadius.circular(999),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        backgroundColor: context.zSurface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        isScrollControlled: true,
        builder: (_) => const ModelPickerSheet(),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: context.zSurfaceAlt,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: context.zBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // A dot that flips green only when the embedded opencode is up,
            // so the chip doubles as a runtime-health indicator.
            Icon(
              Icons.circle,
              size: 7,
              color: ready ? kAccentColor : context.zMuted,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: Text(
                  model.isEmpty ? strings.pickModel : model,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 18,
              color: context.zMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet with the live model catalog advertised by the embedded
/// opencode runtime: search box + paging. Falls back to a "start opencode"
/// hint when the runtime is not yet running, and always allows typing a
/// custom model id (opencode accepts any id its configured providers
/// expose, even ones not listed by `/models`).
class ModelPickerSheet extends ConsumerStatefulWidget {
  const ModelPickerSheet({super.key});

  @override
  ConsumerState<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends ConsumerState<ModelPickerSheet> {
  late final TextEditingController _customController;
  final TextEditingController _searchController = TextEditingController();

  Future<List<OpencodeModel>>? _catalogFuture;
  String? _errorMessage;
  String _query = '';

  @override
  void initState() {
    super.initState();
    // Seed the custom field with the per-chat model when the chat has one,
    // else the app-wide default — mirrors what the chip displays.
    final chatModel = ref.read(
      chatControllerProvider.select((s) => s.opencodeModel),
    );
    _customController = TextEditingController(
      text: chatModel.isNotEmpty
          ? chatModel
          : ref.read(settingsProvider).opencodeModel,
    );
    _reload();
  }

  @override
  void dispose() {
    _customController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Re-fetches the model list from the embedded opencode server. The
  /// future never fails: fetch errors are captured into [_errorMessage]
  /// and surfaced as an empty result, so the UI switches to the error card
  /// without async-error plumbing.
  void _reload() {
    final bool ready = ref.read(opencodeRuntimeProvider).currentStatus.isReady;
    setState(() {
      _errorMessage = null;
      if (ready) {
        _catalogFuture = ref
            .read(opencodeClientProvider)
            .listModels(serverUrl: embeddedOpencodeUrl)
            .then<List<OpencodeModel>>(
              (models) => models,
              onError: (Object e) {
                if (mounted) {
                  setState(() => _errorMessage = e.toString());
                }
                return const <OpencodeModel>[];
              },
            );
      } else {
        _catalogFuture = null;
      }
    });
  }

  void _select(String model) {
    final String trimmed = model.trim();
    if (trimmed.isEmpty) return;
    // v1.0.8: per-chat model (the CLI's /model command). With a chat open
    // the choice applies to THAT chat only and is pushed to its opencode
    // session server-side; without one (fresh app, no chat yet) it lands
    // in the app-wide default like before.
    final hasChat = ref.read(chatControllerProvider).sessionId != null;
    if (hasChat) {
      ref.read(chatControllerProvider.notifier).setChatModel(trimmed);
    } else {
      ref
          .read(settingsProvider.notifier)
          .update(ref.read(settingsProvider).copyWith(opencodeModel: trimmed));
    }
    Navigator.of(context).pop();
  }

  void _setQuery(String value) {
    setState(() => _query = value);
  }

  List<OpencodeModel> _applyFilters(List<OpencodeModel> models) {
    final String q = _query.trim().toLowerCase();
    Iterable<OpencodeModel> out = models;
    if (q.isNotEmpty) {
      out = out.where(
        (m) =>
            m.id.toLowerCase().contains(q) || m.name.toLowerCase().contains(q),
      );
    }
    final List<OpencodeModel> list = out.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final double keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final double sheetHeight = math.max(
      320.0,
      MediaQuery.of(context).size.height * 0.85 - keyboardInset,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SizedBox(
        height: sheetHeight,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _header(strings),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  key: const Key('model-search-field'),
                  controller: _searchController,
                  onChanged: _setQuery,
                  decoration: InputDecoration(
                    hintText: strings.searchModelsHint,
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    isDense: true,
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: strings.cancel,
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              _setQuery('');
                            },
                          ),
                  ),
                ),
              ),
              Divider(height: 1, color: context.zBorder),
              Expanded(child: _body(strings)),
              Divider(height: 1, color: context.zBorder),
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _customController,
                  decoration: InputDecoration(
                    hintText: strings.customModelHint,
                    suffixIcon: IconButton(
                      tooltip: strings.confirm,
                      icon: const Icon(Icons.check_rounded),
                      onPressed: () => _select(_customController.text),
                    ),
                  ),
                  onSubmitted: _select,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(AppStrings strings) {
    final OpencodeRuntimeStatus status = ref.watch(
      opencodeRuntimeProvider.select((b) => b.currentStatus),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  strings.pickModel,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (status.isReady)
                IconButton(
                  key: const Key('model-refresh-button'),
                  tooltip: strings.refreshCatalog,
                  icon: const Icon(Icons.refresh_rounded, size: 22),
                  onPressed: _reload,
                ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: <Widget>[
              Icon(Icons.memory_rounded, size: 13, color: context.zMuted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'opencode · ${status.state.name}'
                  '${status.version.isEmpty ? '' : ' · ${status.version}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: context.zMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _body(AppStrings strings) {
    if (_catalogFuture == null) {
      // opencode runtime not running yet: hint to start it from Settings.
      return PagedList<OpencodeModel>(
        prefix: 'model-empty',
        showSearch: false,
        items: const <OpencodeModel>[],
        resetKey: _query,
        header: <Widget>[_notRunningCard(strings)],
        emptyBuilder: (_) => _emptyCard(strings),
        itemBuilder: (_, __) => const SizedBox.shrink(),
      );
    }
    return FutureBuilder<List<OpencodeModel>>(
      future: _catalogFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                semanticsLabel: strings.fetchingModels,
              ),
            ),
          );
        }
        if (_errorMessage != null) {
          return PagedList<OpencodeModel>(
            prefix: 'model-err',
            showSearch: false,
            items: const <OpencodeModel>[],
            resetKey: _query,
            header: <Widget>[_errorCard(strings)],
            emptyBuilder: (_) => _emptyCard(strings),
            itemBuilder: (_, __) => const SizedBox.shrink(),
          );
        }
        final List<OpencodeModel> filtered = _applyFilters(
          snapshot.data ?? const <OpencodeModel>[],
        );
        return PagedList<OpencodeModel>(
          prefix: 'model',
          showSearch: false,
          items: filtered,
          resetKey: _query,
          emptyBuilder: (_) => _emptyCard(strings),
          itemBuilder: (context, model) => _modelTile(model, strings),
        );
      },
    );
  }

  Widget _modelTile(OpencodeModel model, AppStrings strings) {
    // v1.0.8: selection is per-chat — the chat's override wins, the
    // app-wide default shows as a secondary hint (the CLI shows the
    // session's model the same way).
    final String chatModel = ref.watch(
      chatControllerProvider.select((s) => s.opencodeModel),
    );
    final String appDefault = ref.watch(
      settingsProvider.select((s) => s.opencodeModel),
    );
    final String active = chatModel.isNotEmpty ? chatModel : appDefault;
    final bool selected = model.id == active;
    final bool isFallback = chatModel.isEmpty && model.id == appDefault;
    return ListTile(
      dense: true,
      leading: Icon(
        selected ? Icons.check_circle_rounded : Icons.circle_outlined,
        size: 18,
        color: selected ? kAccentColor : context.zMuted,
        semanticLabel: selected ? strings.activeBadge : null,
      ),
      title: Text(
        model.id,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace'),
      ),
      subtitle: model.name.isEmpty || model.name == model.id
          ? (isFallback
                ? Text(
                    'app default',
                    maxLines: 1,
                    style: TextStyle(fontSize: 11, color: context.zMuted),
                  )
                : null)
          : Text(
              model.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: context.zMuted),
            ),
      onTap: () => _select(model.id),
    );
  }

  Widget _notRunningCard(AppStrings strings) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.zSurfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.zBorder),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.play_circle_outline, size: 18, color: context.zMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Embedded opencode is not running. Start it from '
              'Settings → opencode to load the model list.',
              style: TextStyle(fontSize: 12, color: context.zMuted),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _errorCard(AppStrings strings) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.zSurfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.zBorder),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.cloud_off_rounded, size: 18, color: context.zMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  strings.modelsLoadError,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                key: const Key('model-retry-button'),
                onPressed: _reload,
                child: Text(strings.modelsRetry),
              ),
            ],
          ),
          if (_errorMessage != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _errorMessage!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: context.zMuted,
                  fontFamily: 'monospace',
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _emptyCard(AppStrings strings) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
    child: Column(
      children: <Widget>[
        Icon(Icons.search_off_rounded, size: 32, color: context.zMuted),
        const SizedBox(height: 8),
        Text(
          strings.modelsEmpty,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          strings.modelsEmptyHint,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, color: context.zMuted),
        ),
      ],
    ),
  );
}
