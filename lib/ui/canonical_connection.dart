import 'package:flutter/material.dart';
import '../gateway/hermes_gateway.dart';
import '../gateway/canonical_chat.dart';
import '../gateway/host_invite.dart';
import 'chat_controller.dart';

/// Gateway-first Hermes setup and native conversation browser.
/// Authentication is explicit host trust, not an API-key-to-ticket broker.
class CanonicalConnectionPage extends StatefulWidget {
  const CanonicalConnectionPage(
      {super.key, required this.controller, this.connection, this.session});
  final ChatController controller;
  final Map<String, dynamic>? connection;
  final ChatSession? session;
  @override
  State<CanonicalConnectionPage> createState() =>
      _CanonicalConnectionPageState();
}

class _CanonicalConnectionPageState extends State<CanonicalConnectionPage> {
  final name = TextEditingController(),
      url = TextEditingController(),
      invite = TextEditingController();
  List<GatewaySession> sessions = [];
  String? error;
  bool working = false, importing = false;
  Map<String, dynamic>? connection;
  CanonicalChat? listedOwner;
  @override
  void initState() {
    super.initState();
    name.text = widget.connection?['name'] as String? ?? '';
    url.text = widget.connection?['url'] as String? ?? '';
    connection = widget.connection;
    if (connection != null &&
        widget.controller.canonicalFor(connection!) != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) refresh();
      });
    }
  }

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    invite.dispose();
    super.dispose();
  }

  Future<void> connect() async {
    if (working) return;
    setState(() {
      working = true;
      error = null;
      sessions = [];
      listedOwner = null;
    });
    try {
      final source = HostInviteVault.trustedSource(url.text.trim());
      final c = widget.controller;
      final configured = connection;
      if (configured != null &&
          (!c.isCurrentConnection(configured) ||
              configured['url'] != source.toString())) {
        throw StateError('Original connection changed');
      }
      final existing = configured ??
          c.connections
              .where((v) =>
                  v['type'] == 'hermesGateway' && v['url'] == source.toString())
              .firstOrNull;
      connection = existing;
      if (existing == null) {
        final created = <String, dynamic>{
          'id': 'gateway_${DateTime.now().microsecondsSinceEpoch}',
          'type': 'hermesGateway',
          'name': name.text.trim().isEmpty ? source.host : name.text.trim(),
          'url': source.toString()
        };
        await c.addConnection(created, '');
        connection = c.connections.singleWhere((v) => v['id'] == created['id']);
      }
      if (!mounted) return;
      final credential = invite.text;
      invite
          .clear(); // Never keep a spent ticket visible or use it on reconnect.
      final rows = await c.connectCanonical(connection!, credential);
      if (mounted) {
        setState(() {
          sessions = rows;
          listedOwner = c.canonicalFor(connection!);
          importing = false;
        });
      }
      if (mounted && widget.session != null) {
        final original = widget.session!;
        if (!identical(c.current, original)) {
          throw StateError('Selection changed');
        }
        await c.attachCanonical(
            GatewaySession({
              'session_id': original.remoteSessionId,
              'title': original.remoteTitle ?? '',
            }),
            expectedProfileId: original.canonicalProfileId);
        if (mounted) {
          setState(() => working = false);
          Navigator.pop(context);
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Could not connect or restore the original session. Check the trusted address and use a fresh host-issued invite. Tickets expire after 30 seconds and are single-use. Nothing was sent.');
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> refresh() async {
    if (working || connection == null) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      final owner = widget.controller.canonicalFor(connection!);
      final rows = await widget.controller.listCanonical(connection!);
      if (!identical(owner, widget.controller.canonicalFor(connection!))) {
        throw StateError('Gateway changed');
      }
      if (mounted) {
        setState(() {
          sessions = rows;
          listedOwner = owner;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          sessions = [];
          listedOwner = null;
          error =
              'Could not refresh this host. Existing creation evidence is kept; nothing was sent. Reconnect with a fresh invite if needed.';
        });
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> create() async {
    if (working || connection == null) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      await widget.controller.createCanonical(connection!);
      if (mounted) {
        setState(() => working = false);
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Creation or attachment was not confirmed. A conversation may already exist on the host. Refresh and review its sessions before creating another. No prompt was sent.');
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> dismissCreation() async {
    final owner =
        connection == null ? null : widget.controller.canonicalFor(connection!);
    if (working || owner == null) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Dismiss creation warning?'),
              content: const Text(
                  'The previous conversation may exist on Hermes. Review the host sessions first. This only clears local creation evidence; it does not delete anything on the host. A later New conversation action creates a different conversation.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Keep warning')),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Dismiss warning')),
              ],
            ));
    if (!mounted || confirmed != true) return;
    setState(() => working = true);
    try {
      await owner.creation.dismiss();
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Could not clear creation evidence. Refresh before trying again.');
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> attach(GatewaySession session,
      {CanonicalChat? expectedOwner}) async {
    if (working) return;
    setState(() => working = true);
    try {
      final c = widget.controller;
      if (connection == null ||
          (expectedOwner != null &&
              !identical(expectedOwner, c.canonicalFor(connection!))) ||
          (widget.session != null && !identical(widget.session, c.current))) {
        throw StateError('Gateway or original selection changed');
      }
      await c.attachCanonical(session,
          expectedProfileId: widget.session?.canonicalProfileId ??
              expectedOwner?.client.profileId);
      if (mounted) {
        setState(() => working = false);
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          working = false;
          error = 'Could not attach the original session. Nothing was sent.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final owner = connection == null
            ? null
            : widget.controller.canonicalFor(connection!);
        final listing = listedOwner;
        return PopScope(
            canPop: !working,
            child: Scaffold(
                appBar: AppBar(title: const Text('Hermes gateway')),
                body: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: ListView(
                            padding: const EdgeInsets.all(20),
                            children: [
                              if (widget.session != null)
                                const Padding(
                                    padding: EdgeInsets.only(bottom: 16),
                                    child: Text(
                                        'Reconnect to the original conversation on its original Hermes profile. No history or pending input will be uploaded again.')),
                              if (owner == null || importing) ...[
                                const Text(
                                    'Connect to Hermes using its desktop gateway. Continue native sessions or start a new conversation with the host\'s models, tools and instructions. Only connect to a host you trust.'),
                                const SizedBox(height: 16),
                                TextField(
                                    controller: name,
                                    readOnly: connection != null,
                                    decoration: const InputDecoration(
                                        labelText: 'Connection name')),
                                TextField(
                                    key: const Key('gateway-trusted-url'),
                                    controller: url,
                                    readOnly: connection != null,
                                    autocorrect: false,
                                    decoration: const InputDecoration(
                                        labelText: 'Trusted gateway address',
                                        hintText:
                                            'wss://your-trusted-host/api/ws')),
                                const SizedBox(height: 16),
                                TextField(
                                    controller: invite,
                                    obscureText: true,
                                    enableSuggestions: false,
                                    autocorrect: false,
                                    enableIMEPersonalizedLearning: false,
                                    decoration: const InputDecoration(
                                        labelText: 'Host-issued invite JSON')),
                                const SizedBox(height: 16),
                                const Text('On the Hermes host, run:'),
                                const SelectableText(
                                    'hermes gateway attach --json'),
                                const SizedBox(height: 16),
                                FilledButton(
                                    onPressed: working ? null : connect,
                                    child: Text(working
                                        ? 'Connecting…'
                                        : 'Trust this host and connect')),
                                const SizedBox(height: 8),
                                const Text(
                                    'Invites expire after 30 seconds and are single-use. REST API keys cannot connect to this gateway.'),
                                const ExpansionTile(
                                  title: Text('Local and remote setup'),
                                  children: [
                                    Text(
                                        'Copy the exact gateway address and fresh invite JSON. Local desktop connections may use ws://127.0.0.1:<port>/api/ws. On a phone, localhost means the phone, not your computer.'),
                                    SizedBox(height: 8),
                                    Text(
                                        'Remote connections require trusted WSS and an explicitly secured host forwarding path compatible with Hermes\'s loopback authentication gate. Saathi never rewrites invite URLs or follows redirects. Each reconnect needs a fresh invite.'),
                                  ],
                                ),
                              ] else ...[
                                Text(connection!['name'] as String,
                                    style:
                                        Theme.of(context).textTheme.titleLarge),
                                Text(connection!['url'] as String),
                                const SizedBox(height: 16),
                                const Text(
                                    'Connected to the native gateway. New conversations use the host\'s configured defaults. Creation alone does not send a prompt.'),
                                const SizedBox(height: 16),
                                if (widget.session != null)
                                  FilledButton(
                                      onPressed: working
                                          ? null
                                          : () => attach(
                                              GatewaySession({
                                                'session_id': widget
                                                    .session!.remoteSessionId,
                                                'title': widget
                                                        .session!.remoteTitle ??
                                                    '',
                                              }),
                                              expectedOwner: owner),
                                      child: const Text(
                                          'Open original conversation')),
                                TextButton(
                                    onPressed: working
                                        ? null
                                        : () => setState(() {
                                              importing = true;
                                              sessions = [];
                                              listedOwner = null;
                                              error = null;
                                            }),
                                    child: const Text('Use a fresh invite')),
                                if (owner.creation.problem != null)
                                  Text(owner.creation.problem!),
                                if (owner.creation.pending) ...[
                                  const Text(
                                      'A previous creation needs review. It will not be repeated automatically.'),
                                  if (owner.creation.sessionId != null)
                                    FilledButton(
                                        onPressed: working
                                            ? null
                                            : () => attach(
                                                GatewaySession({
                                                  'session_id':
                                                      owner.creation.sessionId,
                                                  'title': ''
                                                }),
                                                expectedOwner: owner),
                                        child: const Text(
                                            'Open created conversation')),
                                  TextButton(
                                      onPressed:
                                          working ? null : dismissCreation,
                                      child: const Text(
                                          'Dismiss creation warning')),
                                ] else if (widget.session == null)
                                  FilledButton.icon(
                                      onPressed:
                                          working || !owner.creation.canCreate
                                              ? null
                                              : create,
                                      icon: const Icon(Icons.add),
                                      label: const Text(
                                          'New Hermes conversation')),
                                if (!owner.client.canCreateSession)
                                  const Text(
                                      'This host has not advertised native conversation creation. You can still continue an existing session.'),
                                OutlinedButton.icon(
                                    onPressed: working ? null : refresh,
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('Refresh sessions')),
                                const SizedBox(height: 16),
                                Text('Host conversations',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                if (!working && sessions.isEmpty)
                                  const Padding(
                                      padding:
                                          EdgeInsets.symmetric(vertical: 16),
                                      child: Text(
                                          'No conversations returned in this host window. Start one here if supported, or create one on the host and refresh.')),
                              ],
                              if (error != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 16),
                                    child: Text(error!)),
                              if (owner != null &&
                                  !importing &&
                                  identical(owner, listing) &&
                                  widget.session == null)
                                for (final session in sessions)
                                  ListTile(
                                      title: Text(session.title.isEmpty
                                          ? 'Hermes conversation'
                                          : session.title),
                                      subtitle: Text(session.running
                                          ? 'Running on the original host'
                                          : 'On the original host'),
                                      onTap: working
                                          ? null
                                          : () => attach(session,
                                              expectedOwner: listing)),
                              if (sessions.length >= 200)
                                const Text(
                                    'Showing bounded windows of up to 200 sessions per scope, not a complete inventory.'),
                            ])))));
      });
}
