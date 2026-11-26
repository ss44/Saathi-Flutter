import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat_organization/organization.dart';
import '../chat_organization/persona_editor.dart';
import '../core/saathi_core.dart';
import 'chat_controller.dart';
import 'optimizer_settings.dart';

/// Unified conversation settings surface for both compact sheets and desktop
/// workspace panels. It never changes connection ownership or replays history.
class ChatSettingsPanel extends StatefulWidget {
  const ChatSettingsPanel({
    super.key,
    required this.controller,
    required this.session,
    required this.onClose,
    this.isModal = false,
  });

  final ChatController controller;
  final ChatSession session;
  final VoidCallback onClose;

  /// When true, captures system Back navigation to close the compact sheet.
  final bool isModal;

  @override
  State<ChatSettingsPanel> createState() => _ChatSettingsPanelState();
}

class _ChatSettingsPanelState extends State<ChatSettingsPanel> {
  late final TextEditingController _name, _model, _instructions;
  final _sharedInstructions = TextEditingController();
  late final String _initialDisplayName;
  late final Map<String, dynamic>? _connection;
  late final int _selection;
  String? _personaId, _error, _discoveryError;
  bool _saving = false, _discovering = false;
  List<ModelInfo> _discoveredModels = const [];
  int _discoveryRevision = 0;
  int? _discoveryGeneration;
  Completer<void>? _discoverCancel;

  void _cancelDiscovery() {
    final cancel = _discoverCancel;
    _discoverCancel = null;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  ChatController get c => widget.controller;
  ConversationIdentity get identity => c.identityOf(widget.session);

  bool get _native =>
      c.personaPolicy(identity) != PersonaEditPolicy.localInstructions;

  bool get _authorityChanged =>
      _selection != c.selectionGeneration ||
      (_connection != null && !c.isCurrentConnection(_connection));

  bool get _directAuthorityMissing => !_native && _connection == null;

  bool get _catalogValid =>
      !_native &&
      !_authorityChanged &&
      _connection != null &&
      c.canDiscoverModels &&
      _discoveryGeneration == c.catalogGeneration;

  String? get _effectivePersonaId => _personaId != null &&
          c.organization.personas.any((p) => p.id == _personaId)
      ? _personaId
      : null;

  @override
  void initState() {
    super.initState();
    _connection = c.connections
        .where((v) => v['id'] == widget.session.connectionId)
        .firstOrNull;
    _selection = c.selectionGeneration;
    final entry = c.organization.entry(identity);
    _initialDisplayName = entry.displayName;
    _name = TextEditingController(text: entry.displayName)
      ..addListener(_onNameChanged);
    _personaId = entry.personaId;
    _model = TextEditingController(text: c.replyModel(widget.session));
    _instructions = TextEditingController(
        text: entry.instructions ?? widget.session.systemPrompt);
    _refreshSharedInstructions();
  }

  void _onNameChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant ChatSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refreshSharedInstructions();
    if (_discoveredModels.isNotEmpty && !_catalogValid) {
      _cancelDiscovery();
      _discoveryRevision++;
      _discoveredModels = const [];
    }
  }

  void _refreshSharedInstructions() {
    final text = c.organization.personas
            .where((p) => p.id == _effectivePersonaId)
            .firstOrNull
            ?.instructions ??
        '';
    if (_sharedInstructions.text != text) _sharedInstructions.text = text;
  }

  String? get _restriction {
    if (_authorityChanged || _directAuthorityMissing) {
      return 'The conversation or connection changed. Cancel and reopen chat settings.';
    }
    return c.chatSettingsRestriction(widget.session);
  }

  bool get _canEditDirect =>
      !_saving && _restriction == null && !c.organizationBlocked;

  bool get _canRenameNative =>
      _native &&
      !_saving &&
      !_authorityChanged &&
      !c.organizationBlocked &&
      c.sessions.contains(widget.session) &&
      !c.changingConnection &&
      !c.unsavedChanges;

  bool get _nameDirty => _name.text.trim() != _initialDisplayName;

  bool get _canSave => _canEditDirect || (_canRenameNative && _nameDirty);

  Future<void> _discoverModels() async {
    if (!_canEditDirect ||
        _discovering ||
        !c.canDiscoverModels ||
        _connection == null) {
      return;
    }
    _cancelDiscovery();
    final cancel = Completer<void>();
    _discoverCancel = cancel;
    final target = _connection;
    _discoveryGeneration = c.catalogGeneration;
    final revision = ++_discoveryRevision;
    bool valid() =>
        mounted &&
        revision == _discoveryRevision &&
        _discoveryGeneration == c.catalogGeneration &&
        !_authorityChanged &&
        c.isCurrentConnection(target) &&
        c.canDiscoverModels &&
        c.chatSettingsRestriction(widget.session) == null;
    setState(() {
      _discovering = true;
      _discoveredModels = const [];
      _discoveryError = null;
    });
    try {
      final result = await c.discover(
        target,
        isCurrent: valid,
        cancelTrigger: cancel.future,
      );
      if (!valid()) return;
      setState(() {
        _discoveredModels = result;
        if (result.isEmpty) {
          _discoveryError = 'No models returned. Enter a model ID manually.';
        }
      });
    } on ProviderException catch (e) {
      if (valid()) setState(() => _discoveryError = e.message);
    } catch (_) {
      if (valid()) {
        setState(() => _discoveryError =
            'Could not load models. Enter a model ID manually or try again.');
      }
    } finally {
      if (mounted && revision == _discoveryRevision) {
        setState(() {
          _discovering = false;
          if (!valid()) _discoveredModels = const [];
        });
      }
    }
  }

  Future<void> _editPersona({required bool create}) async {
    if (!_canEditDirect) return;
    final existing = c.organization.personas
        .where((p) => p.id == _effectivePersonaId)
        .firstOrNull;
    if (!create && existing == null) return;
    final saved = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SharedPersonaEditDialog(
        organization: c.organization,
        persona: create
            ? SharedPersona(
                id: 'persona-${DateTime.now().microsecondsSinceEpoch}',
                name: '',
                instructions: '',
              )
            : existing!,
        canEdit: (key) {
          final target =
              c.sessions.where((s) => c.identityOf(s) == key).firstOrNull;
          if (target != null) return c.chatSettingsRestriction(target);
          return c.personaPolicy(key) != PersonaEditPolicy.localInstructions
              ? 'Server persona editing is unavailable.'
              : c.pendingPersonaReason(key);
        },
      ),
    );
    if (mounted && saved != null) {
      setState(() {
        _personaId = saved;
        _refreshSharedInstructions();
      });
    } else if (mounted) {
      setState(_refreshSharedInstructions);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_native) {
        await c.renameConversation(
          widget.session,
          originalConnection: _connection,
          selection: _selection,
          displayName: _name.text,
        );
      } else {
        await c.saveChatSettings(
          widget.session,
          originalConnection: _connection,
          selection: _selection,
          model: _model.text,
          instructions: _instructions.text,
          personaId: _effectivePersonaId,
          displayName: _name.text,
        );
      }
      if (mounted) widget.onClose();
    } catch (_) {
      if (mounted) {
        setState(() => _error = c.organization.hasUnsavedChanges
            ? 'Storage recovery could not be confirmed. Keep Saathi open and use Try saving details again before sending. Cancel closes this panel but does not discard recovery.'
            : 'Chat settings were not saved. Check the model and pending work, then try again. Your committed settings are unchanged.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final native = _native;
    final restriction = _restriction;
    final enabled = _canEditDirect;
    final renameEnabled = enabled || _canRenameNative;
    final personaId = _effectivePersonaId;
    final personaSignature = Object.hashAll([
      personaId,
      for (final p in c.organization.personas)
        Object.hash(p.id, p.name, p.revision),
    ]);
    final discoveredModels =
        _catalogValid ? _discoveredModels : const <ModelInfo>[];
    final selectedDiscoveredId = discoveredModels
        .where((m) => m.name == _model.text.trim())
        .map((m) => m.id)
        .firstOrNull;
    return PopScope<void>(
      canPop: !widget.isModal,
      onPopInvokedWithResult: (didPop, _) {
        if (widget.isModal && !didPop && !_saving) widget.onClose();
      },
      child: TextFieldTapRegion(
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (!_saving) widget.onClose();
            }
          },
          child: FocusTraversalGroup(
            child: Material(
              key: const Key('chat-settings-panel'),
              color: Theme.of(context).colorScheme.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Chat settings',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close chat settings',
                          onPressed: _saving ? null : widget.onClose,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Reply connection: ${_connection?['name'] ?? 'Unavailable'}',
                          ),
                          Text(
                            'This conversation stays on its original connection.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            key: const Key('chat-display-name'),
                            controller: _name,
                            enabled: renameEnabled,
                            maxLength: 120,
                            decoration: const InputDecoration(
                              labelText: 'Chat name',
                              hintText: 'Use the first message when blank',
                              counterText: '',
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            key: const Key('chat-reply-model'),
                            controller: _model,
                            enabled: enabled,
                            maxLength: 256,
                            decoration: InputDecoration(
                              labelText: native
                                  ? 'Saved model (server may override)'
                                  : 'Reply model ID',
                              isDense: true,
                            ),
                          ),
                          if (!native) ...[
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              key: const Key('chat-discover-models'),
                              onPressed: enabled &&
                                      !_discovering &&
                                      c.canDiscoverModels
                                  ? _discoverModels
                                  : null,
                              icon: const Icon(Icons.refresh),
                              label: Text(
                                _discovering
                                    ? 'Discovering…'
                                    : 'Discover models',
                              ),
                            ),
                            if (_discoveryError != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  _discoveryError!,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                            if (discoveredModels.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              KeyedSubtree(
                                key: const Key('chat-discovered-models'),
                                child: DropdownButtonFormField<String>(
                                  key: ValueKey(
                                    (_discoveryRevision, selectedDiscoveredId),
                                  ),
                                  initialValue: selectedDiscoveredId,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Available models',
                                  ),
                                  items: [
                                    for (final m in discoveredModels)
                                      DropdownMenuItem(
                                        value: m.id,
                                        child: Text(
                                          m.displayName,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: enabled
                                      ? (id) {
                                          if (id == null || !_catalogValid) {
                                            return;
                                          }
                                          final picked = discoveredModels
                                              .where((m) => m.id == id)
                                              .firstOrNull;
                                          if (picked == null) return;
                                          setState(
                                            () => _model.text = picked.name,
                                          );
                                        }
                                      : null,
                                ),
                              ),
                            ],
                          ],
                          const SizedBox(height: 16),
                          KeyedSubtree(
                            key: const Key('chat-persona'),
                            child: DropdownButtonFormField<String>(
                              key: ValueKey(personaSignature),
                              initialValue: personaId ?? '',
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Assistant persona',
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('This chat’s instructions'),
                                ),
                                for (final persona in c.organization.personas)
                                  DropdownMenuItem(
                                    value: persona.id,
                                    child: Text(
                                      persona.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: enabled
                                  ? (value) => setState(() {
                                        _personaId = value == '' ? null : value;
                                        _refreshSharedInstructions();
                                      })
                                  : null,
                            ),
                          ),
                          if (!native)
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton(
                                  onPressed: enabled
                                      ? () => _editPersona(create: true)
                                      : null,
                                  child: const Text('New persona'),
                                ),
                                if (personaId != null)
                                  TextButton(
                                    onPressed: enabled
                                        ? () => _editPersona(create: false)
                                        : null,
                                    child: const Text('Edit shared persona'),
                                  ),
                              ],
                            ),
                          const SizedBox(height: 12),
                          if (personaId != null)
                            const Text(
                              'This reusable persona supplies the instructions below. Selecting it does not edit the shared persona or other chats. Choose This chat’s instructions to write instructions for only this chat.',
                            ),
                          TextField(
                            key: const Key('chat-instructions'),
                            controller: personaId == null
                                ? _instructions
                                : _sharedInstructions,
                            enabled: enabled && personaId == null,
                            minLines: 3,
                            maxLines: 6,
                            maxLength: 16000,
                            decoration: InputDecoration(
                              labelText: native
                                  ? 'Saved instructions (not server settings)'
                                  : 'System instructions',
                            ),
                          ),
                          const Divider(height: 24),
                          OptimizerSettingsButton(
                            controller: c,
                            chat: widget.session,
                            asTile: true,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Save affects future replies in this chat only. Accepted, queued and uncertain work must be resolved first. Enhance uses its separate destination.',
                          ),
                          if (restriction != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(restriction),
                            ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        TextButton(
                          onPressed: _saving ? null : widget.onClose,
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: _canSave ? _save : null,
                          child: Text(_saving ? 'Saving…' : 'Save'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _cancelDiscovery();
    _discoveryRevision++;
    _name.removeListener(_onNameChanged);
    _name.dispose();
    _model.dispose();
    _instructions.dispose();
    _sharedInstructions.dispose();
    super.dispose();
  }
}
