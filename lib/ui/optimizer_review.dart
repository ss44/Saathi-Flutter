import 'dart:async';
import 'package:flutter/material.dart';
import '../core/saathi_core.dart';
import 'chat_controller.dart';
import 'optimizer_settings.dart';
import 'prompt_optimizer.dart' show rewritePrompt;

/// Returned by [PromptReview] when the user chooses to add a direct connection
/// before picking an optimizer destination.
final class AddDirectConnectionAction {
  const AddDirectConnectionAction();
}

/// Captures the preview destination through the route-result await boundary.
class _ReviewAuthority {
  bool revoked = false;
}

class OptimizerPreview {
  const OptimizerPreview._(
      this.text, this.connection, this.settingsRevision, this._authority);
  final _ReviewAuthority _authority;
  bool get isCurrent => !_authority.revoked;
  final String text;
  final Map<String, dynamic> connection;
  final Object settingsRevision;
}

/// Draft-only consent and preview; never owns a conversation send callback.
class PromptReview extends StatefulWidget {
  const PromptReview(
      {super.key,
      required this.controller,
      required this.draft,
      required this.active,
      required this.ownerValid});
  final ChatController controller;
  final String draft;
  final ValueNotifier<bool> active;
  final bool Function() ownerValid;
  @override
  State<PromptReview> createState() => _PromptReviewState();
}

class _PromptReviewState extends State<PromptReview> {
  ChatController get c => widget.controller;
  OptimizerSelection? selection;
  Map<String, dynamic>? connection;
  _ReviewAuthority ticket = _ReviewAuthority();
  void revoke() {
    ticket.revoked = true;
    ticket = _ReviewAuthority();
  }

  Object? settingsRevision;
  bool verified = false, loading = false, busy = false, _choosing = false;
  String? improved, error;
  SaathiCore? core;
  bool get ownerValid => mounted && widget.active.value && widget.ownerValid();
  bool get valid =>
      ownerValid &&
      !c.optimizerSettingsSaving &&
      verified &&
      connection != null &&
      c.isCurrentConnection(connection!) &&
      !c.changingConnection &&
      identical(settingsRevision, c.optimizerRevision);
  @override
  void initState() {
    super.initState();
    c.addListener(refresh);
    widget.active.addListener(revoked);
    configure();
  }

  void revoked() => scheduleMicrotask(refresh);
  void refresh() {
    if (!mounted) return;
    if (!ownerValid ||
        (connection != null && !c.isCurrentConnection(connection!))) {
      revoke();
      verified = false;
      improved = null;
      busy = false;
      loading = false;
      if (connection != null && !c.isCurrentConnection(connection!)) {
        error =
            'Selected connection changed or was removed. Choose an explicit replacement.';
      }
    }
    if (!_choosing && !identical(settingsRevision, c.optimizerRevision)) {
      configure();
    }
    setState(() {});
  }

  void configure({VerifiedOptimizerChoice? preverified}) {
    revoke();
    core?.close();
    core = null;
    busy = false;
    loading = false;
    improved = null;
    verified = false;
    error = null;
    settingsRevision = c.optimizerRevision;
    if (c.optimizerSettingsSaving) {
      error = 'Saving optimizer destination…';
      return;
    }
    selection = c.optimizerSelection(c.current);
    connection = c.connections
        .where((source) => source['id'] == selection?.connectionId)
        .firstOrNull;
    if (selection == null) {
      error =
          'Choose an optimizer destination. Your chat response model is unchanged.';
      return;
    }
    if (connection == null || !boundedRewriteConnection(connection!['type'])) {
      error =
          'Selected destination unavailable for a bounded text-only rewrite. Choose an explicit replacement; agent tools are not used.';
      return;
    }
    if (ownerValid &&
        preverified != null &&
        preverified.selection == selection &&
        identical(preverified.connection, connection) &&
        preverified.catalogGeneration == c.catalogGeneration &&
        c.isCurrentConnection(connection!) &&
        !c.changingConnection &&
        c.canDiscoverModels) {
      verified = true;
      return;
    }
    loading = true;
    unawaited(verifyCatalog(ticket, connection!, selection!));
  }

  Future<void> verifyCatalog(Object owner, Map<String, dynamic> source,
      OptimizerSelection chosen) async {
    final generation = c.catalogGeneration;
    bool current() =>
        ownerValid &&
        identical(owner, ticket) &&
        c.isCurrentConnection(source) &&
        generation == c.catalogGeneration &&
        identical(settingsRevision, c.optimizerRevision);
    try {
      final models = await c.discover(source, isCurrent: current);
      if (!current()) return;
      verified = models.any((model) =>
          model.name == chosen.model &&
          model.upstreamProvider == chosen.provider);
      if (!verified) {
        error =
            'Selected model is no longer in this connection’s verified catalog. Choose an explicit replacement.';
      }
    } catch (_) {
      if (mounted && identical(owner, ticket)) {
        error =
            'Could not verify the model catalog. Choose a destination to try again.';
      }
    } finally {
      if (mounted && identical(owner, ticket)) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    revoke();
    widget.active.removeListener(revoked);
    c.removeListener(refresh);
    core?.close();
    super.dispose();
  }

  Future<void> choose() async {
    if (!ownerValid || _choosing) return;
    _choosing = true;
    VerifiedOptimizerChoice? chosen;
    try {
      chosen = await showDialog<VerifiedOptimizerChoice>(
          context: context,
          builder: (_) => OptimizerSettingsDialog(
              controller: c,
              chat: c.current,
              isOwnerCurrent: () => ownerValid));
    } finally {
      _choosing = false;
    }
    if (!ownerValid) return;
    setState(() => configure(preverified: chosen));
  }

  void addDirectConnection() {
    if (!ownerValid || !c.canChangeConnections) return;
    Navigator.pop(context, const AddDirectConnectionAction());
  }

  Future<void> improve() async {
    if (!valid || busy) return;
    final source = connection!;
    final chosen = selection!;
    final owner = ticket;
    bool current() =>
        valid &&
        identical(ticket, owner) &&
        identical(source, connection) &&
        chosen == selection;
    setState(() {
      busy = true;
      error = null;
    });
    SaathiCore? request;
    try {
      final key = await c.store
          .readConnectionSecret(source['id'])
          .timeout(const Duration(seconds: 30));
      if (!current()) return;
      request = c.coreFactory();
      core = request;
      final text = await rewritePrompt(
          request, c.config(source, key ?? ''), chosen.model, widget.draft);
      if (!current()) return;
      setState(() => improved = text);
    } catch (_) {
      if (current()) {
        setState(() => error =
            'Could not enhance this draft. Nothing was changed. Check the connection and model.');
      }
    } finally {
      request?.close();
      if (identical(request, core)) core = null;
      if (mounted && identical(owner, ticket)) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasDirect =
        c.connections.any((e) => boundedRewriteConnection(e['type']));
    return AlertDialog(
        title: const Text('Enhance prompt'),
        content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const Text(
                      'Sends only this draft (no chat history) as one additional AI request; provider charges may apply. Review before applying; nothing is sent to your conversation.'),
                  const SizedBox(height: 12),
                  Text(c.current != null &&
                          c.optimizerOverride(c.current!) != null
                      ? 'Using chat override'
                      : 'Inheriting global setting'),
                  if (selection != null)
                    Text(
                        'Destination: ${connection?['name'] ?? selection!.connectionId} · ${connection?['url'] ?? ''} · ${selection!.provider == null ? '' : '${selection!.provider} · '}${selection!.model}'),
                  if (!hasDirect) ...[
                    const SizedBox(height: 8),
                    const Text(
                        'No direct text connection available. Hermes and OpenClaw agent runtimes cannot safely be used for this rewrite.'),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                        onPressed: ownerValid && c.canChangeConnections
                            ? addDirectConnection
                            : null,
                        icon: const Icon(Icons.add),
                        label: const Text('Add direct connection')),
                  ],
                  TextButton(
                      onPressed: ownerValid ? choose : null,
                      child: const Text('Choose optimizer')),
                  if (loading) const Text('Checking model catalog…'),
                  const Text('Original',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SelectableText(widget.draft),
                  if (busy)
                    const Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator()),
                  if (error != null) Text(error!),
                  if (!ownerValid)
                    const Text(
                        'Draft or conversation changed. Close this preview and try again.'),
                  if (improved != null) ...[
                    const Divider(),
                    const Text('Enhanced',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    SelectableText(improved!)
                  ],
                ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(busy ? 'Cancel' : 'Keep original')),
          if (improved == null)
            FilledButton(
                onPressed: busy || !valid ? null : improve,
                child: const Text('Enhance')),
          if (improved != null)
            FilledButton(
                onPressed: valid
                    ? () {
                        if (valid) {
                          Navigator.pop(
                              context,
                              OptimizerPreview._(improved!, connection!,
                                  settingsRevision!, ticket));
                        }
                      }
                    : null,
                child: const Text('Apply')),
        ]);
  }
}
