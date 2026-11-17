import 'package:flutter/material.dart';
import 'organization.dart';

class ConversationEditDialog extends StatefulWidget {
  const ConversationEditDialog(
      {super.key,
      required this.organization,
      required this.identity,
      required this.fallbackInstructions,
      required this.policy,
      required this.pendingReason});
  final ChatOrganization organization;
  final ConversationIdentity identity;
  final String fallbackInstructions;
  final PersonaEditPolicy Function(ConversationIdentity) policy;
  final String? Function(ConversationIdentity) pendingReason;
  @override
  State<ConversationEditDialog> createState() => _ConversationEditDialogState();
}

class _ConversationEditDialogState extends State<ConversationEditDialog> {
  late final TextEditingController _name;
  String? _personaId, _error;
  bool _saving = false, _failedSave = false;
  @override
  void initState() {
    super.initState();
    final entry = widget.organization.entry(widget.identity);
    _name = TextEditingController(text: entry.displayName);
    _personaId = entry.personaId;
  }

  String? get _restriction => widget.policy(widget.identity) !=
          PersonaEditPolicy.localInstructions
      ? 'Persona editing is unavailable for this server conversation. No history will be copied.'
      : widget.pendingReason(widget.identity);
  Future<void> _persona({required bool create}) async {
    final existing = widget.organization.personas
        .where((p) => p.id == _personaId)
        .firstOrNull;
    final saved = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SharedPersonaEditDialog(
            organization: widget.organization,
            persona: create
                ? SharedPersona(
                    id: 'persona-${DateTime.now().microsecondsSinceEpoch}',
                    name: '',
                    instructions: '')
                : existing!,
            canEdit: (key) =>
                widget.policy(key) != PersonaEditPolicy.localInstructions
                    ? 'Server persona editing is unavailable.'
                    : widget.pendingReason(key)));
    if (mounted && saved != null) setState(() => _personaId = saved);
  }

  Future<void> _save() async {
    if (widget.organization.saving ||
        (!_failedSave && widget.organization.hasUnsavedChanges)) {
      setState(() => _error =
          'Recover the existing unsaved conversation details first. Your draft is unchanged.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_failedSave) {
        await widget.organization.retrySave();
      } else {
        await widget.organization.edit(widget.identity,
            displayName: _name.text,
            personaId: _personaId,
            policy: widget.policy(widget.identity),
            pendingReason: widget.pendingReason(widget.identity),
            revalidatePersonaChange: () => _restriction);
      }
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failedSave = widget.organization.hasUnsavedChanges;
          _error = widget.organization.error ??
              'Could not save. Check pending work and try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_saving && !_failedSave,
      child: AlertDialog(
          title: const Text('Edit conversation'),
          content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    TextField(
                        key: const ValueKey('conversation-name'),
                        controller: _name,
                        maxLength: 120,
                        enabled: !_saving && !_failedSave,
                        decoration: const InputDecoration(
                            labelText: 'Chat name',
                            hintText: 'Use the first message when blank')),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                        key: ValueKey(_personaId),
                        initialValue: _personaId ?? '',
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: 'Assistant persona'),
                        items: [
                          const DropdownMenuItem(
                              value: '', child: Text('Original instructions')),
                          for (final persona in widget.organization.personas)
                            DropdownMenuItem(
                                value: persona.id,
                                child: Text(persona.name,
                                    overflow: TextOverflow.ellipsis))
                        ],
                        onChanged:
                            _saving || _failedSave || _restriction != null
                                ? null
                                : (id) => setState(
                                    () => _personaId = id == '' ? null : id)),
                    const SizedBox(height: 12),
                    Wrap(children: [
                      TextButton(
                          onPressed:
                              _saving || _failedSave || _restriction != null
                                  ? null
                                  : () => _persona(create: true),
                          child: const Text('New persona')),
                      if (_personaId != null)
                        TextButton(
                            onPressed:
                                _saving || _failedSave || _restriction != null
                                    ? null
                                    : () => _persona(create: false),
                            child: const Text('Edit shared persona'))
                    ]),
                    Text(widget.organization.personas
                            .where((p) => p.id == _personaId)
                            .firstOrNull
                            ?.instructions ??
                        widget.fallbackInstructions),
                    const SizedBox(height: 12),
                    const Text(
                        'Personas are reusable assistant roles, not connections or server workspaces. Changes affect future messages only; earlier replies stay unchanged.'),
                    if (_restriction != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(_restriction!)),
                    if (_error != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(_error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error))),
                  ]))),
          actionsOverflowDirection: VerticalDirection.down,
          actions: [
            TextButton(
                onPressed: _saving
                    ? null
                    : () {
                        if (_failedSave) {
                          widget.organization.discardPendingEdit();
                        }
                        Navigator.pop(context);
                      },
                child: const Text('Cancel')),
            FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_failedSave ? 'Try saving again' : 'Save'))
          ]));
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }
}

/// Editing this entity deliberately affects every attached chat. The dialog
/// discloses those chats and revalidates each one's lifecycle at Save.
class SharedPersonaEditDialog extends StatefulWidget {
  const SharedPersonaEditDialog(
      {super.key,
      required this.organization,
      required this.persona,
      required this.canEdit});
  final ChatOrganization organization;
  final SharedPersona persona;
  final String? Function(ConversationIdentity) canEdit;
  @override
  State<SharedPersonaEditDialog> createState() =>
      _SharedPersonaEditDialogState();
}

class _SharedPersonaEditDialogState extends State<SharedPersonaEditDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.persona.name);
  late final TextEditingController _instructions =
      TextEditingController(text: widget.persona.instructions);
  bool _saving = false, _failedSave = false;
  String? _error;
  Future<void> _save() async {
    if (widget.organization.saving ||
        (!_failedSave && widget.organization.hasUnsavedChanges)) {
      setState(() => _error =
          'Recover the existing unsaved conversation details first. Your draft is unchanged.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // A failed storage write is not permission to bypass new pending work.
      for (final chat in widget.organization.affectedChats(widget.persona.id)) {
        final reason = widget.canEdit(chat);
        if (reason != null) throw StateError(reason);
      }
      if (_failedSave) {
        await widget.organization.retrySave();
      } else {
        await widget.organization.savePersona(
            SharedPersona(
                id: widget.persona.id,
                name: _name.text,
                instructions: _instructions.text),
            canEdit: widget.canEdit);
      }
      if (mounted) {
        Navigator.pop(context, widget.persona.id);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failedSave = widget.organization.hasUnsavedChanges;
          _error = widget.organization.error ??
              'Could not save. Check the persona name and pending conversations.';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final affected = widget.organization.affectedChats(widget.persona.id);
    return PopScope(
        canPop: !_saving && !_failedSave,
        child: AlertDialog(
            title: const Text('Shared persona'),
            content: SizedBox(
                width: 360,
                child: SingleChildScrollView(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      TextField(
                          key: const ValueKey('persona-name'),
                          controller: _name,
                          maxLength: 80,
                          enabled: !_saving && !_failedSave,
                          decoration:
                              const InputDecoration(labelText: 'Persona name')),
                      TextField(
                          key: const ValueKey('persona-instructions'),
                          controller: _instructions,
                          minLines: 3,
                          maxLines: 8,
                          maxLength: 16000,
                          enabled: !_saving && !_failedSave,
                          decoration: const InputDecoration(
                              labelText: 'Assistant instructions')),
                      Text(
                          'Saving changes this shared role for future interaction in ${affected.length} conversations. Accepted and queued messages keep their captured instructions.'),
                      for (final chat in affected)
                        Text(
                            '• ${widget.organization.entry(chat).title('Unnamed conversation')}'),
                      const Text(
                          'Saving a persona does not attach it until you Save the conversation. It never changes a provider or server workspace.'),
                      if (_error != null) Text(_error!),
                    ]))),
            actionsOverflowDirection: VerticalDirection.down,
            actions: [
              TextButton(
                  onPressed: _saving
                      ? null
                      : () {
                          if (_failedSave) {
                            widget.organization.discardPendingEdit();
                          }
                          Navigator.pop(context);
                        },
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: _saving ? null : _save,
                  child:
                      Text(_failedSave ? 'Try saving again' : 'Save persona'))
            ]));
  }

  @override
  void dispose() {
    _name.dispose();
    _instructions.dispose();
    super.dispose();
  }
}
