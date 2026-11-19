import 'dart:convert';
import 'package:flutter/material.dart';
import '../core/saathi_core.dart';
import '../storage/saathi_store.dart' show StorageRecoveryException;
import 'chat_controller.dart';

/// Persisted destination only. No credentials, URLs, or response-model state.
@immutable
class OptimizerSelection {
  const OptimizerSelection(
      {required this.connectionId, required this.model, this.provider});
  final String connectionId, model;
  final String? provider;
  Map<String, dynamic> toJson() => {
        'connectionId': connectionId,
        'model': model,
        if (provider != null) 'provider': provider
      };
  static OptimizerSelection? fromJson(dynamic value) {
    if (value is! Map ||
        value['connectionId'] is! String ||
        value['model'] is! String ||
        (value['provider'] != null && value['provider'] is! String)) {
      return null;
    }
    if ((value['connectionId'] as String).isEmpty ||
        (value['model'] as String).isEmpty) {
      return null;
    }
    return OptimizerSelection(
        connectionId: value['connectionId'],
        model: value['model'],
        provider: value['provider']);
  }

  @override
  bool operator ==(Object other) =>
      other is OptimizerSelection &&
      connectionId == other.connectionId &&
      model == other.model &&
      provider == other.provider;
  @override
  int get hashCode => Object.hash(connectionId, model, provider);
}

class _Settings {
  _Settings(ChatController c) {
    try {
      final raw = jsonDecode(
          c.store.preferences.getString('saathi.optimizer.v1') ?? '{}');
      global = OptimizerSelection.fromJson(raw['global']);
      if (raw['chats'] is Map) {
        for (final entry in (raw['chats'] as Map).entries) {
          final selection = OptimizerSelection.fromJson(entry.value);
          if (entry.key is String && selection != null) {
            chats[entry.key] = selection;
          }
        }
      }
    } catch (_) {/* Invalid local settings require explicit selection. */}
  }
  OptimizerSelection? global;
  Map<String, OptimizerSelection> chats = {};
  Object revision = Object();
  bool saving = false;
}

final _settings = Expando<_Settings>();

/// Settings are independent from conversation transport and history persistence.
extension OptimizerSettings on ChatController {
  _Settings get _optimizer => _settings[this] ??= _Settings(this);
  Object get optimizerRevision => _optimizer.revision;
  bool get optimizerSettingsSaving => _optimizer.saving;
  OptimizerSelection? get globalOptimizerSelection => _optimizer.global;
  OptimizerSelection? optimizerOverride(ChatSession chat) =>
      _optimizer.chats[chat.id];
  OptimizerSelection? optimizerSelection(ChatSession? chat) =>
      (chat == null ? null : optimizerOverride(chat)) ??
      globalOptimizerSelection;

  /// Commit runtime state only after durable storage succeeds. Every attempted
  /// change revokes pending rewrite authority, including failed/round-trip edits.
  Future<void> saveOptimizerSelection(OptimizerSelection? selection,
      {ChatSession? chat}) async {
    final state = _optimizer;
    if (state.saving) throw StateError('Settings save already in progress');
    state.saving = true;
    state.revision = Object();
    notifyListeners();
    try {
      final chats = {...state.chats};
      var global = state.global;
      if (chat == null) {
        global = selection;
      } else if (selection == null) {
        chats.remove(chat.id);
      } else {
        chats[chat.id] = selection;
      }
      final payload = jsonEncode({
        'global': global?.toJson(),
        'chats': {
          for (final entry in chats.entries) entry.key: entry.value.toJson()
        }
      });
      const key = 'saathi.optimizer.v1';
      final preferences = store.preferences;
      final before = preferences.get(key);
      try {
        if (!await preferences.setString(key, payload)) {
          throw StateError('Could not save optimizer settings');
        }
      } catch (_) {
        // The plugin mutates its cache before a durable write succeeds. Restore
        // the exact prior raw value so a new controller cannot adopt a failed
        // selection. Keep the save guard through compensation as well.
        try {
          final restored = await switch (before) {
            null => preferences.remove(key),
            String value => preferences.setString(key, value),
            bool value => preferences.setBool(key, value),
            int value => preferences.setInt(key, value),
            double value => preferences.setDouble(key, value),
            // The platform codec can decode a string list as List<Object?>.
            List value => preferences.setStringList(key, value.cast<String>()),
            _ => throw const StorageRecoveryException(),
          };
          if (!restored) throw const StorageRecoveryException();
        } catch (_) {
          throw const StorageRecoveryException();
        }
        rethrow;
      }
      state.global = global;
      state.chats = chats;
    } finally {
      state.saving = false;
      state.revision = Object();
      notifyListeners();
    }
  }
}

bool boundedRewriteConnection(String? type) =>
    const ['openai', 'anthropic', 'gemini'].contains(type);

/// Grouped source-bound catalog picker. Native runtimes are visible but disabled;
/// discovery never changes server configuration or sends a draft.
class OptimizerSettingsButton extends StatelessWidget {
  const OptimizerSettingsButton(
      {super.key, required this.controller, this.chat, this.asTile = false});
  final ChatController controller;
  final ChatSession? chat;
  final bool asTile;
  @override
  Widget build(BuildContext context) {
    final title =
        chat == null ? 'Global prompt optimizer' : 'Chat prompt optimizer';
    void open() => showDialog<void>(
        context: context,
        builder: (_) => OptimizerSettingsDialog(
            controller: controller,
            chat: chat,
            isOwnerCurrent: () => context.mounted));
    if (asTile) {
      return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.tune),
          title: Text(title),
          subtitle: Text(chat == null
              ? 'Default rewrite model, separate from chat replies'
              : controller.optimizerOverride(chat!) == null
                  ? 'Inheriting global setting'
                  : 'Override for this chat'),
          trailing: const Icon(Icons.chevron_right),
          onTap: open);
    }
    return IconButton(
        tooltip: title, icon: const Icon(Icons.tune), onPressed: open);
  }
}

class OptimizerSettingsDialog extends StatefulWidget {
  const OptimizerSettingsDialog(
      {super.key, required this.controller, this.chat, this.isOwnerCurrent});
  final ChatController controller;
  final ChatSession? chat;
  final bool Function()? isOwnerCurrent;
  @override
  State<OptimizerSettingsDialog> createState() =>
      _OptimizerSettingsDialogState();
}

class _OptimizerSettingsDialogState extends State<OptimizerSettingsDialog>
    with WidgetsBindingObserver {
  bool saving = false;
  String? error;
  late final session = widget.controller.current;
  bool revoked = false;
  bool get valid =>
      mounted &&
      !revoked &&
      (widget.isOwnerCurrent?.call() ?? true) &&
      widget.controller.canDiscoverModels &&
      (widget.chat == null || identical(session, widget.controller.current));
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(refresh);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      revoked = true;
      if (mounted) setState(() {});
    }
  }

  void refresh() {
    if (widget.chat != null && !identical(session, widget.controller.current)) {
      revoked = true;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(refresh);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> save(OptimizerSelection? value) async {
    if (!valid || saving) return;
    final route = ModalRoute.of(context);
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.controller.saveOptimizerSelection(value, chat: widget.chat);
      if (mounted) {
        setState(() => saving = false);
        // Dismissal leaves this widget mounted during its reverse transition.
        // An accepted save may finish, but may only pop its own current route.
        if (route != null && route.isCurrent) route.navigator?.pop();
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          saving = false;
          error = failure is StorageRecoveryException
              ? 'Could not confirm storage recovery. Choose and save a destination again before restarting.'
              : 'Could not save. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final selected = c.optimizerSelection(widget.chat);
    final selectedConnection = c.connections
        .where((source) => source['id'] == selected?.connectionId)
        .firstOrNull;
    return AlertDialog(
        title: Text(widget.chat == null
            ? 'Global prompt optimizer'
            : 'Chat prompt optimizer'),
        content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  if (revoked)
                    const Text(
                        'Settings paused. Close and reopen to choose safely.'),
                  const Text(
                      'Separate from the chat response model. Choose a connection, then a verified model. No draft is shared while choosing.'),
                  Text(
                      'Selected: ${selected == null ? 'Not configured' : '${selectedConnection?['name'] ?? 'Unavailable connection (${selected.connectionId})'} · ${selected.provider == null ? '' : '${selected.provider} · '}${selected.model}'}'),
                  if (widget.chat != null)
                    Text(c.optimizerOverride(widget.chat!) == null
                        ? 'Inheriting global setting'
                        : 'Override for this chat'),
                  if (widget.chat != null)
                    TextButton(
                        onPressed: saving ? null : () => save(null),
                        child: const Text('Inherit global setting')),
                  for (final connection in c.connections)
                    _ConnectionModels(
                        key: ObjectKey(connection),
                        controller: c,
                        connection: connection,
                        enabled: !saving && valid,
                        isOwnerCurrent: () => valid,
                        onSelect: save),
                  if (error != null) Text(error!),
                ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'))
        ]);
  }
}

class _ConnectionModels extends StatefulWidget {
  const _ConnectionModels(
      {super.key,
      required this.controller,
      required this.connection,
      required this.enabled,
      required this.isOwnerCurrent,
      required this.onSelect});
  final ChatController controller;
  final Map<String, dynamic> connection;
  final bool enabled;
  final bool Function() isOwnerCurrent;
  final ValueChanged<OptimizerSelection> onSelect;
  @override
  State<_ConnectionModels> createState() => _ConnectionModelsState();
}

class _ConnectionModelsState extends State<_ConnectionModels> {
  List<ModelInfo>? models;
  bool loading = false;
  String? error;
  Object ticket = Object();
  int? generation;
  Object? settingsRevision;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(refresh);
  }

  void refresh() {
    if (!mounted) return;
    if (!widget.controller.canDiscoverModels ||
        !widget.isOwnerCurrent() ||
        !widget.controller.isCurrentConnection(widget.connection) ||
        generation != widget.controller.catalogGeneration ||
        !identical(settingsRevision, widget.controller.optimizerRevision)) {
      ticket = Object();
      setState(() {
        models = null;
        loading = false;
        error = 'Catalog changed. Try again.';
      });
    }
  }

  @override
  void dispose() {
    ticket = Object();
    widget.controller.removeListener(refresh);
    super.dispose();
  }

  Future<void> load() async {
    final c = widget.controller;
    if (loading || !widget.enabled) return;
    final source = widget.connection;
    final owner = ticket = Object();
    final generation = this.generation = c.catalogGeneration;
    final revision = settingsRevision = c.optimizerRevision;
    bool valid() =>
        mounted &&
        identical(owner, ticket) &&
        widget.enabled &&
        widget.isOwnerCurrent() &&
        c.isCurrentConnection(source) &&
        generation == c.catalogGeneration &&
        identical(revision, c.optimizerRevision);
    setState(() {
      loading = true;
      models = null;
      error = null;
    });
    try {
      final result = await c.discover(source, isCurrent: valid);
      if (valid()) setState(() => models = result);
    } catch (_) {
      if (mounted && identical(owner, ticket)) {
        setState(() => error = 'Catalog unavailable. Try again.');
      }
    } finally {
      if (mounted && identical(owner, ticket)) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.connection;
    final supported = boundedRewriteConnection(source['type']);
    return ExpansionTile(
        enabled: supported && widget.enabled,
        title: Text(source['name'] as String),
        subtitle: supported
            ? null
            : const Text(
                'Bounded text-only rewrite unavailable. Agent tools are not used.'),
        onExpansionChanged: supported
            ? (open) {
                if (open) load();
              }
            : null,
        children: [
          if (supported) ...[
            if (loading) const LinearProgressIndicator(),
            if (error != null) TextButton(onPressed: load, child: Text(error!)),
            if (models != null && models!.isEmpty)
              const Text('No verified models available.'),
            for (final model in models ?? <ModelInfo>[])
              ListTile(
                  title: Text(model.name),
                  subtitle: model.upstreamProvider == null
                      ? null
                      : Text(model.upstreamProvider!),
                  onTap: widget.enabled &&
                          widget.isOwnerCurrent() &&
                          widget.controller.canDiscoverModels &&
                          generation == widget.controller.catalogGeneration &&
                          identical(settingsRevision,
                              widget.controller.optimizerRevision) &&
                          widget.controller.isCurrentConnection(source)
                      ? () => widget.onSelect(OptimizerSelection(
                          connectionId: source['id'],
                          model: model.name,
                          provider: model.upstreamProvider))
                      : null),
          ]
        ]);
  }
}
