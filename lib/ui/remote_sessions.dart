import 'package:flutter/material.dart';
import '../chat_organization/organization_widgets.dart'
    show readOnlyConversationTileColor;
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

class _RemoteSessionsPageState extends State<RemoteSessionsPage>
    with WidgetsBindingObserver {
  final sessions = <RemoteSession>[];
  bool loading = true, more = false;
  bool runSubmissionSupported = true;
  int offset = 0;
  String? error;
  SaathiCore? active;
  bool inFlight = false;
  int _openGeneration = 0;
  bool _openingSession = false;
  bool _suspended = false;
  bool get current =>
      mounted && widget.controller.isCurrentConnection(widget.connection);
  void connectionChanged() {
    if (!current || widget.controller.changingConnection) {
      _openGeneration++;
      if (mounted && _openingSession) {
        setState(() => _openingSession = false);
      }
    }
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _suspended = state != AppLifecycleState.resumed;
    if (_suspended) {
      _openGeneration++;
      if (mounted && _openingSession) {
        setState(() => _openingSession = false);
      }
    }
  }

  @override
  void dispose() {
    _openGeneration++;
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
    load();
  }

  bool _isContinuedLocally(RemoteSession session) =>
      session.source == 'api_server' &&
      widget.controller.sessions.any(
        (local) =>
            local.connectionId == widget.connection['id'] &&
            local.remoteSessionId == session.id,
      );

  Future<void> _openSession(RemoteSession session) async {
    if (!current || _openingSession) return;
    final interactive = session.isInteractiveApiSession(
      runSubmissionSupported: runSubmissionSupported,
    );
    if (!interactive) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => RemoteHistoryPage(
            controller: widget.controller,
            connection: widget.connection,
            session: session,
          ),
        ),
      );
      return;
    }
    if (widget.controller.attachingRemote) return;
    final owner = ++_openGeneration;
    final selection = widget.controller.selectionGeneration;
    bool stillOwned() =>
        mounted &&
        !_suspended &&
        owner == _openGeneration &&
        selection == widget.controller.selectionGeneration &&
        !widget.controller.changingConnection &&
        widget.controller.isCurrentConnection(widget.connection) &&
        (ModalRoute.of(context)?.isCurrent ?? false);
    setState(() => _openingSession = true);
    try {
      await widget.controller.continueRemote(
        widget.connection,
        session,
        isOwnerCurrent: stillOwned,
      );
      if (mounted &&
          !_suspended &&
          owner == _openGeneration &&
          widget.controller.isCurrentConnection(widget.connection) &&
          (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } on RemoteContinuationUnavailable catch (failure) {
      if (mounted && stillOwned()) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => RemoteHistoryPage(
              controller: widget.controller,
              connection: widget.connection,
              session: session,
              initialAttachmentError: failure.message,
            ),
          ),
        );
      }
    } on ProviderException catch (failure) {
      if (mounted && stillOwned()) {
        final loadError = failure.statusCode == 401 || failure.statusCode == 403
            ? 'This connection does not have permission to read this conversation. Check its credentials and session access, then try again.'
            : 'Could not read conversations. Try again.';
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => RemoteHistoryPage(
              controller: widget.controller,
              connection: widget.connection,
              session: session,
              initialLoadError: loadError,
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted && stillOwned()) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => RemoteHistoryPage(
              controller: widget.controller,
              connection: widget.connection,
              session: session,
              initialAttachmentError:
                  'Could not connect to this conversation. Check this connection’s Runs support and session access, then try again. Nothing was sent.',
            ),
          ),
        );
      }
    } finally {
      if (mounted && owner == _openGeneration) {
        setState(() => _openingSession = false);
      }
    }
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
      var supportsRuns = runSubmissionSupported;
      if (offset == 0) {
        final capabilities =
            await core.discoverCapabilities(widget.connection['id']);
        final features = capabilities['features'];
        supportsRuns = features is! Map || features['run_submission'] != false;
      }
      if (!current) return;
      final page = await core.listRemoteSessions(widget.connection['id'],
          offset: offset);
      if (current) {
        setState(() {
          runSubmissionSupported = supportsRuns;
          sessions.addAll(page.sessions
              .where((s) => !sessions.any((old) => old.id == s.id)));
          final ordered = RemoteSession.orderByRecency(
            sessions,
            runSubmissionSupported: runSubmissionSupported,
          );
          sessions
            ..clear()
            ..addAll(ordered);
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
      body: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) =>
              ListView(padding: const EdgeInsets.all(20), children: [
                const Text('On your server',
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                const Text(
                    'API-owned conversations can continue through native Runs after checking this connection. Desktop / CLI conversations require a canonical gateway grant, not the API-server key. History is never replayed into another conversation.'),
                if (_openingSession) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                const SizedBox(height: 16),
                for (final session in sessions)
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      tileColor: !session.isInteractiveApiSession(
                        runSubmissionSupported: runSubmissionSupported,
                      )
                          ? readOnlyConversationTileColor(context)
                          : null,
                      leading: const Icon(Icons.cloud_outlined),
                      title: Text(session.title),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                              '${session.source ?? 'Remote'} · ${session.source == 'api_server' ? (runSubmissionSupported ? 'Native continuation' : 'Runs unavailable') : 'Gateway connection required'}'),
                          if (_isContinuedLocally(session))
                            const Text('On this device'),
                          if (!session.isInteractiveApiSession(
                            runSubmissionSupported: runSubmissionSupported,
                          ))
                            const Text('Read-only'),
                        ],
                      ),
                      onTap:
                          _openingSession ? null : () => _openSession(session)),
                if (error != null)
                  Text(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                if (loading)
                  const Center(
                      child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator()))
                else if (more || error != null)
                  OutlinedButton(
                      onPressed: load,
                      child: Text(
                          error == null ? 'Load more sessions' : 'Try again'))
                else if (sessions.isEmpty)
                  const Text('No remote sessions returned.'),
              ])));
}

class RemoteHistoryPage extends StatefulWidget {
  const RemoteHistoryPage(
      {super.key,
      required this.controller,
      required this.connection,
      required this.session,
      this.isReadAuthorityCurrent,
      this.initialAttachmentError,
      this.initialLoadError});
  final ChatController controller;
  final Map<String, dynamic> connection;
  final RemoteSession session;
  final bool Function()? isReadAuthorityCurrent;

  /// Optional attachment failure already observed before opening this history
  /// view, allowing read-only inspection without an immediate duplicate attach.
  final String? initialAttachmentError;

  /// Optional history-read failure already observed before opening this view.
  final String? initialLoadError;
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
  String? _pendingAttachmentError;
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
    _pendingAttachmentError = null;
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
    _pendingAttachmentError = widget.initialAttachmentError;
    if (widget.initialLoadError != null) {
      loading = false;
      error = widget.initialLoadError;
    } else {
      open();
    }
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
    if (!current || error != null || widget.session.source != 'api_server') {
      return;
    }
    final initialError = _pendingAttachmentError;
    if (initialError != null) {
      _pendingAttachmentError = null;
      if (mounted) setState(() => attachmentError = initialError);
      return;
    }
    await attach();
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
