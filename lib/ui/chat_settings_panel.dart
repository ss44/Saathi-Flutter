import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../chat_organization/organization.dart';
import 'chat_controller.dart';

/// Desktop-only conversation surface. It never changes connection ownership.
class ChatSettingsPanel extends StatefulWidget {
  const ChatSettingsPanel(
      {super.key,
      required this.controller,
      required this.session,
      required this.onClose});
  final ChatController controller;
  final ChatSession session;
  final VoidCallback onClose;

  @override
  State<ChatSettingsPanel> createState() => _ChatSettingsPanelState();
}

class _ChatSettingsPanelState extends State<ChatSettingsPanel> {
  late final TextEditingController _model, _instructions;
  final _sharedInstructions = TextEditingController();
  late final Map<String, dynamic>? _connection;
  late final int _selection;
  String? _personaId, _error;
  bool _saving = false;
  ChatController get c => widget.controller;
  ConversationIdentity get identity => c.identityOf(widget.session);

  @override
  void initState() {
    super.initState();
    _connection = c.connections
        .where((v) => v['id'] == widget.session.connectionId)
        .firstOrNull;
    _selection = c.selectionGeneration;
    _personaId = c.organization.entry(identity).personaId;
    _model = TextEditingController(text: c.replyModel(widget.session));
    _instructions = TextEditingController(
        text: c.organization.entry(identity).instructions ??
            widget.session.systemPrompt);
    _refreshSharedInstructions();
  }

  @override
  void didUpdateWidget(covariant ChatSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refreshSharedInstructions();
  }

  void _refreshSharedInstructions() {
    final text = c.organization.personas
            .where((p) => p.id == _personaId)
            .firstOrNull
            ?.instructions ??
        '';
    if (_sharedInstructions.text != text) _sharedInstructions.text = text;
  }

  String? get _restriction {
    if (_selection != c.selectionGeneration ||
        _connection == null ||
        !c.isCurrentConnection(_connection)) {
      return 'The conversation or connection changed. Cancel and reopen chat settings.';
    }
    return c.chatSettingsRestriction(widget.session);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await c.saveChatSettings(widget.session,
          originalConnection: _connection,
          selection: _selection,
          model: _model.text,
          instructions: _instructions.text,
          personaId: _personaId);
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
    final native =
        c.personaPolicy(identity) != PersonaEditPolicy.localInstructions;
    final restriction = _restriction;
    final enabled = !_saving && restriction == null && !c.organizationBlocked;
    return TextFieldTapRegion(
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
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Chat settings',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              Text(
                  'Reply connection: ${_connection?['name'] ?? 'Unavailable'}'),
              const Text('This conversation stays on its original connection.'),
              const SizedBox(height: 16),
              TextField(
                key: const Key('chat-reply-model'),
                controller: _model,
                enabled: enabled,
                maxLength: 256,
                decoration: InputDecoration(
                    labelText: native
                        ? 'Saved model (server may override)'
                        : 'Reply model ID'),
              ),
              DropdownButtonFormField<String>(
                key: const Key('chat-persona'),
                initialValue: _personaId ?? '',
                isExpanded: true,
                decoration:
                    const InputDecoration(labelText: 'Assistant persona'),
                items: [
                  const DropdownMenuItem(
                      value: '', child: Text('This chat’s instructions')),
                  for (final persona in c.organization.personas)
                    DropdownMenuItem(
                        value: persona.id,
                        child: Text(persona.name,
                            overflow: TextOverflow.ellipsis)),
                ],
                onChanged: enabled
                    ? (value) => setState(() {
                          _personaId = value == '' ? null : value;
                          _refreshSharedInstructions();
                        })
                    : null,
              ),
              const SizedBox(height: 16),
              if (_personaId != null)
                const Text(
                    'This reusable persona supplies the instructions below. Selecting it does not edit the shared persona or other chats. Choose This chat’s instructions to write instructions for only this chat.'),
              TextField(
                key: const Key('chat-instructions'),
                controller:
                    _personaId == null ? _instructions : _sharedInstructions,
                enabled: enabled && _personaId == null,
                minLines: 3,
                maxLines: 6,
                maxLength: 16000,
                decoration: InputDecoration(
                    labelText: native
                        ? 'Saved instructions (not server settings)'
                        : 'System instructions'),
              ),
              const SizedBox(height: 12),
              const Text(
                  'Save affects future replies in this chat only. Accepted, queued and uncertain work must be resolved first. Enhance uses its separate destination.'),
              if (restriction != null)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(restriction)),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 16),
              Wrap(spacing: 12, children: [
                TextButton(
                    onPressed: _saving ? null : widget.onClose,
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: enabled ? _save : null,
                    child: Text(_saving ? 'Saving…' : 'Save')),
              ]),
            ]),
          ),
        ),
      ),
    ));
  }

  @override
  void dispose() {
    _model.dispose();
    _instructions.dispose();
    _sharedInstructions.dispose();
    super.dispose();
  }
}
