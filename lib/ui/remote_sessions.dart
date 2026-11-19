import 'package:flutter/material.dart';
import '../core/saathi_core.dart';
import 'chat_controller.dart';
import 'chat_home.dart' show MessageView;
import 'transcript_presentation.dart';
import 'canonical_connection.dart';

class RemoteSessionsPage extends StatefulWidget {
  const RemoteSessionsPage(
      {super.key, required this.controller, required this.connection});
  final ChatController controller;
  final Map<String, dynamic> connection;
  @override
  State<RemoteSessionsPage> createState() => _RemoteSessionsPageState();
}

class _RemoteSessionsPageState extends State<RemoteSessionsPage> {
  final sessions = <RemoteSession>[];
  bool loading = true, more = false;
  int offset = 0;
  String? error;
  SaathiCore? active;
  bool inFlight = false;
  bool get current =>
      mounted && widget.controller.isCurrentConnection(widget.connection);
  void connectionChanged() {
    if (!current && mounted) {
      active?.close();
      setState(() {
        sessions.clear();
        more = false;
        error = 'Connection unavailable.';
        loading = false;
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(connectionChanged);
    active?.close();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(connectionChanged);
    load();
  }

  Future<void> load() async {
    if (inFlight || !current) return;
    inFlight = true;
    setState(() {
      loading = true;
      error = null;
    });
    SaathiCore? core;
    try {
      core = await widget.controller.coreFor(widget.connection);
      if (!current) return;
      active = core;
      if (offset == 0) await core.discoverCapabilities(widget.connection['id']);
      if (!current) return;
      final page = await core.listRemoteSessions(widget.connection['id'],
          offset: offset);
      if (current) {
        setState(() {
          sessions.addAll(page.sessions
              .where((s) => !sessions.any((old) => old.id == s.id)));
          offset = page.offset + page.limit;
          more = page.hasMore;
        });
      }
    } on ProviderException {
      if (current) {
        setState(() => error = 'Could not read conversations. Try again.');
      }
    } catch (_) {
      if (current) {
        setState(() => error =
            'Could not read remote sessions. Check server compatibility and credentials.');
      }
    } finally {
      core?.close();
      active = null;
      inFlight = false;
      if (current) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text('${widget.connection['name']} sessions')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('On your server',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        const Text(
            'API-owned conversations can continue through native Runs after checking this connection. Desktop / CLI conversations require a canonical gateway grant, not the API-server key. History is never replayed into another conversation.'),
        const SizedBox(height: 16),
        for (final session in sessions)
          ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cloud_outlined),
              title: Text(session.title),
              subtitle: Text(
                  '${session.source ?? 'Remote'} · ${session.source == 'api_server' ? 'Native continuation' : 'Gateway connection required'}'),
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => RemoteHistoryPage(
                          controller: widget.controller,
                          connection: widget.connection,
                          session: session)))),
        if (error != null)
          Text(error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (loading)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator()))
        else if (more || error != null)
          OutlinedButton(
              onPressed: load,
              child: Text(error == null ? 'Load more sessions' : 'Try again'))
        else if (sessions.isEmpty)
          const Text('No remote sessions returned.'),
      ]));
}

class RemoteHistoryPage extends StatefulWidget {
  const RemoteHistoryPage(
      {super.key,
      required this.controller,
      required this.connection,
      required this.session,
      this.isReadAuthorityCurrent});
  final ChatController controller;
  final Map<String, dynamic> connection;
  final RemoteSession session;
  final bool Function()? isReadAuthorityCurrent;
  @override
  State<RemoteHistoryPage> createState() => _RemoteHistoryPageState();
}

class _RemoteHistoryPageState extends State<RemoteHistoryPage>
    with WidgetsBindingObserver {
  final messages = <Map<String, dynamic>>[];
  int offset = 0;
  bool loading = true, more = false;
  String? error;
  SaathiCore? active;
  bool inFlight = false;
  bool opening = false, revoked = false, suspended = false;
  String? attachmentError;
  bool get available =>
      mounted &&
      !suspended &&
      !widget.controller.changingConnection &&
      widget.controller.isCurrentConnection(widget.connection) &&
      (widget.isReadAuthorityCurrent?.call() ?? true);
  bool get current => available && !revoked;
  void connectionChanged() {
    if (!available && mounted) invalidate();
  }

  void invalidate() {
    revoked = true;
    active?.close();
    setState(() {
      messages.clear();
      offset = 0;
      more = false;
      error = 'Connection changed or paused. Try again when it is available.';
      loading = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    suspended = state != AppLifecycleState.resumed;
    if (suspended) invalidate();
  }

  Future<void> retry() async {
    if (!available || inFlight || opening) return;
    revoked = false;
    await open();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(connectionChanged);
    active?.close();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(connectionChanged);
    open();
  }

  Future<void> load() async {
    if (inFlight || !current) return;
    inFlight = true;
    setState(() {
      loading = true;
      error = null;
    });
    SaathiCore? core;
    try {
      core = await widget.controller.coreFor(widget.connection);
      if (!current) return;
      active = core;
      final page = await core.loadRemoteHistory(
          widget.connection['id'], widget.session.id,
          offset: offset);
      if (current) {
        setState(() {
          messages.addAll(page.messages);
          final pagination = page.pagination;
          final pageOffset = pagination['offset'] as int? ?? offset;
          final returned =
              pagination['returned'] as int? ?? page.messages.length;
          final limit = pagination['limit'] as int? ?? 100;
          offset = pageOffset + returned;
          final hasMore = pagination['has_more'];
          more = page.messages.isNotEmpty &&
              returned > 0 &&
              (hasMore is bool ? hasMore : returned >= limit);
        });
      }
    } on ProviderException catch (failure) {
      if (current) {
        setState(() => error = failure.statusCode == 401 ||
                failure.statusCode == 403
            ? 'This connection does not have permission to read this conversation. Check its credentials and session access, then try again.'
            : 'Could not read conversations. Try again.');
      }
    } catch (_) {
      if (current) setState(() => error = 'Could not read remote history.');
    } finally {
      core?.close();
      active = null;
      inFlight = false;
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> open() async {
    await load();
    if (current && error == null && widget.session.source == 'api_server') {
      await attach();
    }
  }

  /// Opening is read/attach only. Sending stays with the original chat owner.
  Future<void> attach() async {
    if (!current || opening) return;
    setState(() {
      opening = true;
      attachmentError = null;
    });
    try {
      await widget.controller.continueRemote(widget.connection, widget.session,
          isOwnerCurrent: () =>
              current && (ModalRoute.of(context)?.isCurrent ?? false));
      if (mounted && current) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } on RemoteContinuationUnavailable catch (failure) {
      if (mounted) setState(() => attachmentError = failure.message);
    } catch (_) {
      if (mounted) {
        setState(() => attachmentError =
            'Could not connect to this conversation. Check this connection’s Runs support and session access, then try again. Nothing was sent.');
      }
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title: Text(
              widget.session.title.trim().isEmpty
                  ? 'New conversation'
                  : widget.session.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis)),
      body: ListView(padding: const EdgeInsets.all(22), children: [
        Text(
            widget.session.source == 'api_server'
                ? (error != null || attachmentError != null
                    ? 'Conversation connection unavailable'
                    : 'Connecting to this conversation…')
                : 'Gateway connection required',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        if (widget.session.source != 'api_server') ...[
          const Text(
              'This connection can read this session, but cannot send to it through the API. Connect to the original host with a fresh authenticated gateway invite and select the authorized session there. History will not be copied to another chat.'),
          OutlinedButton(
              onPressed: !current
                  ? null
                  : () => Navigator.push(
                      context,
                      CanonicalConnectionRoute<void>(
                          builder: (_) => CanonicalConnectionPage(
                              controller: widget.controller))),
              child: const Text('Connect to original host')),
        ],
        if (opening) const LinearProgressIndicator(),
        if (attachmentError != null) ...[
          Text(attachmentError!),
          OutlinedButton(
              onPressed: current && !opening ? attach : null,
              child: const Text('Try connecting again')),
        ],
        const Divider(height: 32),
        for (final message in messages.map(projectRemoteHistory).nonNulls)
          if (showsHistoryBubble(message))
            MessageView(text: message.content, user: message.role == 'user'),
        if (error != null)
          Text(error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (loading)
          const Center(child: CircularProgressIndicator())
        else if (more || error != null)
          OutlinedButton(
              onPressed: !available || inFlight || opening
                  ? null
                  : error == null
                      ? load
                      : retry,
              child: Text(error == null ? 'Load more history' : 'Try again')),
      ]));
}
