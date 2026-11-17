import 'package:flutter/material.dart';
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
  bool _failedRefresh = false;
  int offset = 0;
  SaathiCore? active;
  bool get current => !disposed && controller.isCurrentConnection(connection);
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
      await core.discoverCapabilities(connection['id']);
      if (!current) return;
      final page = await core.listRemoteSessions(connection['id'],
          offset: refresh ? 0 : offset);
      if (!current) return;
      update(() {
        if (refresh) sessions.clear();
        for (final session in page.sessions) {
          if (!sessions.any((s) => s.id == session.id)) sessions.add(session);
        }
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
                    title: Text(session.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
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
