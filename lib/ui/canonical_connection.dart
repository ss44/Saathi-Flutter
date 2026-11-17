import 'package:flutter/material.dart';
import '../gateway/hermes_gateway.dart';
import '../gateway/host_invite.dart';
import 'chat_controller.dart';

/// Manual host-issued invitation, not a dashboard/admin login or API-key broker.
class CanonicalConnectionPage extends StatefulWidget {
  const CanonicalConnectionPage(
      {super.key, required this.controller, this.connection});
  final ChatController controller;
  final Map<String, dynamic>? connection;
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
  bool working = false;
  @override
  void initState() {
    super.initState();
    name.text = widget.connection?['name'] as String? ?? '';
    url.text = widget.connection?['url'] as String? ?? '';
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
    });
    try {
      final source = HostInviteVault.trustedSource(url.text.trim());
      final c = widget.controller;
      var connection = c.connections
          .where((v) =>
              v['type'] == 'hermesGateway' && v['url'] == source.toString())
          .firstOrNull;
      if (connection == null) {
        connection = {
          'id': 'gateway_${DateTime.now().microsecondsSinceEpoch}',
          'type': 'hermesGateway',
          'name': name.text.trim().isEmpty ? source.host : name.text.trim(),
          'url': source.toString()
        };
        await c.addConnection(connection, '');
        connection =
            c.connections.singleWhere((v) => v['id'] == connection!['id']);
      }
      if (!mounted) return;
      final credential = invite.text;
      invite
          .clear(); // Never keep a spent ticket visible or use it on reconnect.
      final rows = await c.connectCanonical(connection, credential);
      if (mounted) setState(() => sessions = rows);
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Could not connect. Check the trusted WSS host and import a fresh host-issued invite. Tickets expire after 30 seconds and are single-use.');
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> attach(GatewaySession session) async {
    setState(() => working = true);
    try {
      await widget.controller.attachCanonical(session);
      if (mounted) Navigator.pop(context);
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
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Hermes Desktop / CLI')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text(
            'Connect only to a host you trust. This grants access to its authorized Hermes sessions, not a new API chat.'),
        const SizedBox(height: 16),
        TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Connection name')),
        TextField(
            key: const Key('gateway-trusted-url'),
            controller: url,
            autocorrect: false,
            decoration: const InputDecoration(
                labelText: 'Trusted WSS address',
                hintText: 'wss://your-trusted-host/api/ws')),
        const SizedBox(height: 16),
        TextField(
            controller: invite,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            enableIMEPersonalizedLearning: false,
            decoration:
                const InputDecoration(labelText: 'Host-issued invite JSON')),
        const SizedBox(height: 16),
        const Text(
            'On the trusted host: hermes gateway attach --json. Native tickets are loopback-only: the host must provide an explicitly secured TLS forwarding path. A normal API key cannot create this invite. The invite URL must exactly match the trusted address; Saathi never rewrites or follows it. Reconnect requires a fresh invite.'),
        const SizedBox(height: 16),
        FilledButton(
            onPressed: working ? null : connect,
            child:
                Text(working ? 'Connecting…' : 'Trust this host and connect')),
        if (error != null)
          Padding(padding: const EdgeInsets.only(top: 16), child: Text(error!)),
        for (final session in sessions)
          ListTile(
              title: Text(session.title.isEmpty
                  ? 'Hermes conversation'
                  : session.title),
              subtitle: Text(session.running
                  ? 'Running on the original host'
                  : 'On the original host'),
              onTap: working ? null : () => attach(session)),
        if (sessions.length >= 200)
          const Text(
              'Showing bounded windows of up to 200 sessions per scope, not a complete inventory.'),
      ]));
}
