import 'package:flutter/material.dart';
import '../chat_organization/organization_widgets.dart'
    show readOnlyConversationTileColor;
import '../core/saathi_core.dart' hide RemoteHistoryPage;
import 'chat_controller.dart';
import 'remote_sessions.dart';

/// Cache lifetime belongs to ChatHome, not the transient native drawer child.
class ConversationServerCache extends ChangeNotifier {
  ConversationServerCache(this.controller, this.connection);
  final ChatController controller;
  final Map<String, dynamic> connection;
  final sessions = <RemoteSession>[];
  bool loading = false, loaded = false, failed = false, more = false;
  bool disposed = false;
  bool runSubmissionSupported = true;
  bool _failedRefresh = false;
  int offset = 0;
  SaathiCore? active;
  bool get current => !disposed && controller.isCurrentConnection(connection);
  bool isSessionReadOnly(RemoteSession session) =>
      !session.isInteractiveApiSession(
        runSubmissionSupported: runSubmissionSupported,
      );

  /// Returns the local [ChatSession] already continuing [session] on this
  /// exact HTTP Hermes connection, if any. Non-API sessions stay separate
  /// because they require canonical gateway authority.
  ChatSession? localContinuationFor(RemoteSession session) {
    if (session.source != 'api_server') return null;
    final connectionId = connection['id'];
    for (final local in controller.sessions) {
      if (local.connectionId == connectionId &&
          local.remoteSessionId == session.id) {
        return local;
      }
    }
    return null;
  }

  /// Remote sessions not already represented by a local continued chat.
  List<RemoteSession> get visibleSessions => [
        for (final session in sessions)
          if (localContinuationFor(session) == null) session,
      ];

  void update(VoidCallback action) {
    action();
    if (!disposed) notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    active?.close();
    super.dispose();
  }

  Future<void> retry() => load(refresh: _failedRefresh);

  Future<void> load({bool refresh = false}) async {
    if (loading || !current) return;
    update(() {
      loading = true;
      failed = false;
    });
    SaathiCore? core;
    try {
      core = await controller.coreFor(connection);
      if (!current) return;
      active = core;
      final capabilities = await core.discoverCapabilities(connection['id']);
      if (!current) return;
      final features = capabilities['features'];
      final supportsRuns =
          features is! Map || features['run_submission'] != false;
      final page = await core.listRemoteSessions(connection['id'],
          offset: refresh ? 0 : offset);
      if (!current) return;
      update(() {
        runSubmissionSupported = supportsRuns;
        if (refresh) sessions.clear();
        for (final session in page.sessions) {
          if (!sessions.any((s) => s.id == session.id)) sessions.add(session);
        }
        final ordered = RemoteSession.orderByRecency(
          sessions,
          runSubmissionSupported: runSubmissionSupported,
        );
        sessions
          ..clear()
          ..addAll(ordered);
        offset = page.offset + page.limit;
        more = page.hasMore;
        loaded = true;
      });
    } catch (_) {
      if (current) {
        update(() {
          failed = true;
          _failedRefresh = refresh;
          loaded = true;
        });
      }
    } finally {
      core?.close();
      active = null;
      if (current) update(() => loading = false);
    }
  }
}

class ConversationServer extends StatelessWidget {
  const ConversationServer(
      {super.key,
      required this.cache,
      this.closeDrawerOnOpen = true,
      this.onOpenSession});
  final ConversationServerCache cache;

  /// Persistent sidebars must not pop the app route when opening history.
  final bool closeDrawerOnOpen;

  /// Optional handler allowing [ChatHome] to attach interactive API sessions
  /// smoothly without pushing a transient [RemoteHistoryPage] route.
  final void Function(
    Map<String, dynamic> connection,
    RemoteSession session, {
    required bool interactive,
  })? onOpenSession;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: Listenable.merge([cache, cache.controller]),
      builder: (context, _) {
        final visibleSessions = cache.visibleSessions;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
                title: Text(cache.connection['name'] as String),
                trailing: IconButton(
                    tooltip: 'Refresh',
                    onPressed:
                        cache.loading ? null : () => cache.load(refresh: true),
                    icon: const Icon(Icons.refresh))),
            for (final session in visibleSessions)
              ListTile(
                  tileColor: cache.isSessionReadOnly(session)
                      ? readOnlyConversationTileColor(context)
                      : null,
                  title: Text(session.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: cache.isSessionReadOnly(session)
                      ? const Text('Read-only')
                      : null,
                  onTap: () {
                    if (!cache.current) return;
                    final interactive = !cache.isSessionReadOnly(session);
                    final navigator = Navigator.of(context);
                    if (closeDrawerOnOpen) navigator.pop();
                    final openHandler = onOpenSession;
                    if (openHandler != null) {
                      openHandler(
                        cache.connection,
                        session,
                        interactive: interactive,
                      );
                      return;
                    }
                    navigator.push(MaterialPageRoute<void>(
                        builder: (_) => RemoteHistoryPage(
                            controller: cache.controller,
                            connection: cache.connection,
                            session: session)));
                  }),
            if (cache.loading) const ListTile(title: Text('Loading chats')),
            if (cache.failed)
              TextButton(
                  onPressed: cache.loading ? null : cache.retry,
                  child: const Text('Try again')),
            if (!cache.loading &&
                !cache.failed &&
                cache.loaded &&
                visibleSessions.isEmpty)
              ListTile(
                  title: Text(cache.sessions.isEmpty
                      ? 'No conversations'
                      : 'All loaded chats are on this device')),
            if (cache.more && !cache.loading && !cache.failed)
              TextButton(onPressed: cache.load, child: const Text('Load more')),
          ],
        );
      });
}
