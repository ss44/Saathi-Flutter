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
      {super.key, required this.cache, this.closeDrawerOnOpen = true});
  final ConversationServerCache cache;

  /// Persistent sidebars must not pop the app route when opening history.
  final bool closeDrawerOnOpen;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: cache,
      builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                  title: Text(cache.connection['name'] as String),
                  trailing: IconButton(
                      tooltip: 'Refresh',
                      onPressed: cache.loading
                          ? null
                          : () => cache.load(refresh: true),
                      icon: const Icon(Icons.refresh))),
              for (final session in cache.sessions)
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
                      final navigator = Navigator.of(context);
                      if (closeDrawerOnOpen) navigator.pop();
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
                  cache.sessions.isEmpty)
                const ListTile(title: Text('No conversations')),
              if (cache.more && !cache.loading && !cache.failed)
                TextButton(
                    onPressed: cache.load, child: const Text('Load more')),
            ],
          ));
}
