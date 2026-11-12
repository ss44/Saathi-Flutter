import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../core/saathi_core.dart';
import 'chat_controller.dart';
import 'safe_markdown.dart';

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
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    SaathiCore? core;
    try {
      core = await widget.controller.coreFor(widget.connection);
      if (offset == 0) await core.discoverCapabilities(widget.connection['id']);
      final page = await core.listRemoteSessions(widget.connection['id'],
          offset: offset);
      if (mounted) {
        setState(() {
          sessions.addAll(page.sessions
              .where((s) => !sessions.any((old) => old.id == s.id)));
          offset = page.offset + page.limit;
          more = page.hasMore;
        });
      }
    } on ProviderException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Could not read remote sessions. Check server compatibility and credentials.');
      }
    } finally {
      core?.close();
      if (mounted) setState(() => loading = false);
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
            'Read-only browsing. Existing desktop / CLI conversations cannot be taken over using REST. Their history is never replayed into a new conversation.'),
        const SizedBox(height: 16),
        for (final session in sessions)
          ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cloud_outlined),
              title: Text(session.title),
              subtitle: Text('${session.source ?? 'Remote'} · Read-only'),
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
      required this.session});
  final ChatController controller;
  final Map<String, dynamic> connection;
  final RemoteSession session;
  @override
  State<RemoteHistoryPage> createState() => _RemoteHistoryPageState();
}

class _RemoteHistoryPageState extends State<RemoteHistoryPage> {
  final messages = <Map<String, dynamic>>[];
  int offset = 0;
  bool loading = true, more = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    SaathiCore? core;
    try {
      core = await widget.controller.coreFor(widget.connection);
      final page = await core.loadRemoteHistory(
          widget.connection['id'], widget.session.id,
          offset: offset);
      if (mounted) {
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
    } on ProviderException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'Could not read remote history.');
    } finally {
      core?.close();
      if (mounted) setState(() => loading = false);
    }
  }

  String visibleContent(dynamic content) {
    if (content is String) return content;
    if (content is List) {
      return content
          .whereType<Map>()
          .where((b) => b['type'] == 'text')
          .map((b) => b['text'] is String ? b['text'] : '')
          .join('\n');
    }
    return '';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(widget.session.title)),
      body: ListView(padding: const EdgeInsets.all(22), children: [
        const Text('Read-only · Server-owned conversation',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        const Text(
            'Live attachment is not available in this build. No messages or transcript will be uploaded from this screen. Only public user and assistant text is shown.'),
        const Divider(height: 32),
        for (final m in messages
            .where((m) => ['user', 'assistant', 'model'].contains(m['role'])))
          if (visibleContent(m['content']).isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m['role'] == 'user' ? 'You' : 'Assistant',
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      MarkdownBody(
                          data: visibleContent(m['content']),
                          imageBuilder: safeMarkdownImageBuilder,
                          selectable: true)
                    ])),
        if (error != null)
          Text(error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (loading)
          const Center(child: CircularProgressIndicator())
        else if (more || error != null)
          OutlinedButton(
              onPressed: load,
              child: Text(error == null ? 'Load more history' : 'Try again')),
      ]));
}
