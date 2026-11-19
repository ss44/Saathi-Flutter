import 'package:flutter/material.dart';
import '../gateway/hermes_gateway.dart';
import '../gateway/host_invite.dart';
import 'chat_controller.dart';

/// Attachment routes revoke pending navigation synchronously on every cover or
/// removal, including dialogs and zero-duration push/pop round trips. This is
/// deliberately local to native connection pages, not an app-wide observer.
class CanonicalConnectionRoute<T> extends MaterialPageRoute<T> {
  CanonicalConnectionRoute({required super.builder});

  VoidCallback? _revokeAttachment;

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    if (nextRoute != null) _revokeAttachment?.call();
    super.didChangeNext(nextRoute);
  }

  @override
  void didComplete(T? result) {
    _revokeAttachment?.call();
    super.didComplete(result);
  }
}

/// Manual host-issued invitation, not a dashboard/admin login or API-key broker.
/// App navigation must use [CanonicalConnectionRoute] so non-animated covers
/// revoke authority as well as ordinary Material route transitions.
class CanonicalConnectionPage extends StatefulWidget {
  const CanonicalConnectionPage(
      {super.key,
      required this.controller,
      this.connection,
      this.targetSession});
  final ChatController controller;
  final Map<String, dynamic>? connection;

  /// Reconnect an already-bound conversation, never infer its old profile.
  final ChatSession? targetSession;
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
  ModalRoute<dynamic>? _attachmentRoute;
  bool _attachmentRevoked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_attachmentRoute != null &&
        (!identical(route, _attachmentRoute) || !route!.isCurrent)) {
      _attachmentRevoked = true;
    }
  }

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
      final selection = c.selectionGeneration;
      var connection = widget.targetSession != null
          ? widget.connection
          : c.connections
              .where((v) =>
                  v['type'] == 'hermesGateway' && v['url'] == source.toString())
              .firstOrNull;
      if (widget.targetSession != null &&
          (connection == null ||
              !c.isCurrentConnection(connection) ||
              connection['url'] != source.toString())) {
        throw StateError('Original connection required');
      }
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
      if (!mounted) return;
      if (selection != c.selectionGeneration) {
        throw StateError('Conversation selection changed');
      }
      final target = widget.targetSession;
      if (target != null) {
        await attach(GatewaySession({
          'session_id': target.remoteSessionId,
          'title': target.title,
        }));
      } else {
        setState(() => sessions = rows);
      }
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Could not connect. Check the trusted WSS host and import a fresh host-issued invite. Tickets expire after 30 seconds and are single-use.');
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  void _covered(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) _attachmentRevoked = true;
  }

  void _leaving(AnimationStatus status) {
    if (status == AnimationStatus.reverse ||
        status == AnimationStatus.dismissed) {
      _attachmentRevoked = true;
    }
  }

  Future<void> attach(GatewaySession session) async {
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    _attachmentRoute = route;
    _attachmentRevoked = false;
    if (route is CanonicalConnectionRoute) {
      route._revokeAttachment = () => _attachmentRevoked = true;
    }
    // Retain MaterialPageRoute embedding compatibility. Status listeners run
    // inside its route event, before a frame; dependencies alone are too late.
    route.secondaryAnimation?.addStatusListener(_covered);
    route.animation?.addStatusListener(_leaving);
    bool ownsRoute() => mounted && !_attachmentRevoked && route.isCurrent;
    setState(() => working = true);
    try {
      await widget.controller.attachCanonical(session,
          expectedSession: widget.targetSession, isOwnerCurrent: ownsRoute);
      if (mounted && ownsRoute()) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          working = false;
          error =
              'Could not attach the original host profile and session. Check its access and reconnect with a fresh invite from that host. Nothing was sent.';
        });
      }
    } finally {
      if (route is CanonicalConnectionRoute) route._revokeAttachment = null;
      route.secondaryAnimation?.removeStatusListener(_covered);
      route.animation?.removeStatusListener(_leaving);
      _attachmentRoute = null;
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
            readOnly: widget.targetSession != null,
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
