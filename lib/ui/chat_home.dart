import 'dart:async';
import '../agent_activity/activity_owner.dart';
import '../agent_activity/activity_strip.dart';
import '../agent_activity/activity_model.dart';
import '../core/saathi_core.dart' show RemoteSession;
import 'remote_sessions.dart';
import 'package:flutter/material.dart';
import 'local_history_search.dart';
import '../update_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../agent_runs/run_client.dart';
import '../agent_controls/agent_controls.dart';
import '../agent_controls/agent_controls_panel.dart';
import 'chat_controller.dart';
import 'busy_thinking.dart';
import 'connections.dart';
import 'safe_markdown.dart';
import 'conversation_servers.dart';
import 'prompt_optimizer.dart';

const muted = Color(0xFF6A7470);

class ChatHome extends StatefulWidget {
  const ChatHome({super.key, required this.controller});
  final ChatController controller;
  @override
  State<ChatHome> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<ChatHome> with WidgetsBindingObserver {
  late ActivityOwner activity;
  bool drawerOpen = false;
  AgentControlsController? controls;
  bool openingControls = false;
  Object controlsOwner = Object();
  StreamSubscription<ScopedRunSnapshot>? controlsUpdates;

  void revokeControls() {
    controlsOwner = Object();
    controls?.revoke();
    controls = null;
  }

  Future<void> reviewControls() async {
    if (openingControls || controls != null) return;
    openingControls = true;
    final owner = controlsOwner;
    AgentControlsController? acquired;
    try {
      final controller = await c.openRunControls(
          isOwnerCurrent: () => mounted && identical(owner, controlsOwner));
      if (controller == null) return;
      acquired = controller;
      controls = controller;
      if (!mounted) {
        revokeControls();
        return;
      }
      await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          showDragHandle: true,
          builder: (context) => SizedBox(
              height: MediaQuery.sizeOf(context).height * .75,
              child: AnimatedBuilder(
                  animation: c,
                  builder: (context, _) => controller.isCurrent
                      ? AgentControlsPanel(
                          controller: controller, redact: controller.redact)
                      : const Center(
                          child: Text('Request no longer available.')))));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Could not open requests. Check status and try again.')));
      }
    } finally {
      revokeControls();
      acquired?.dispose();
      openingControls = false;
    }
  }

  final serverCaches = <Map<String, dynamic>, ConversationServerCache>{};
  @override
  void initState() {
    super.initState();
    activity = ActivityOwner(c);
    WidgetsBinding.instance.addObserver(this);
    c.addListener(syncServers);
    listenControls();
    c.pauseRuns(
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed);
    syncServers();
  }

  void listenControls() {
    controlsUpdates = c.scopedRunSnapshots.listen((event) {
      final controller = controls;
      if (controller == null ||
          !controller.isCurrent ||
          !event.isCurrent() ||
          event.localChatId != c.current?.id ||
          event.operationKey != c.currentRun?.key ||
          !identical(event.connectionRevision,
              controller.boundary.scope.authorityToken)) {
        return;
      }
      try {
        controller.updateSnapshot(PendingControlsSnapshot.fromJson(
            controller.boundary.scope, event.snapshot.data));
        // The normal poll is authoritative; never issue another poll from it.
      } catch (_) {/* The next explicit refresh reports malformed status. */}
    });
  }

  void syncServers() {
    if (controls != null && !controls!.isCurrent) revokeControls();
    for (final connection in serverCaches.keys.toList()) {
      if (!c.isCurrentConnection(connection)) {
        serverCaches.remove(connection)!.dispose();
      }
    }
    for (final connection
        in c.connections.where((c) => c['type'] == 'hermes')) {
      final cache = serverCaches.putIfAbsent(
          connection, () => ConversationServerCache(c, connection));
      if (drawerOpen && !cache.loaded && !cache.loading) cache.load();
    }
  }

  @override
  void didUpdateWidget(covariant ChatHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, c)) return;
    revokeControls();
    controlsUpdates?.cancel();
    oldWidget.controller.removeListener(syncServers);
    oldWidget.controller.pauseRuns(true);
    activity.dispose();
    for (final cache in serverCaches.values) {
      cache.dispose();
    }
    serverCaches.clear();
    activity = ActivityOwner(c);
    c.addListener(syncServers);
    listenControls();
    final paused =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    c.pauseRuns(paused);
    activity.setPaused(paused);
    syncServers();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    c.setQueueBackground(state != AppLifecycleState.resumed);
    c.pauseRuns(state != AppLifecycleState.resumed);
    activity.setPaused(state != AppLifecycleState.resumed);
    if (state != AppLifecycleState.resumed) revokeControls();
  }

  void openActivityParent(ActivityBinding binding) {
    if (activity.connectionFor(binding) == null) return;
    final session =
        c.sessions.where((s) => s.id == binding.localChatId).firstOrNull;
    if (session == null) return;
    setState(() {
      c.current = session;
      composer.clear();
    });
    c.notifyListeners();
  }

  void openActivityChild(ActivityBinding binding, ChildActivity child) {
    final connection = activity.connectionFor(binding);
    if (connection == null || child.childSessionId == null) return;
    Navigator.push(
        context,
        MaterialPageRoute<void>(
            builder: (_) => RemoteHistoryPage(
                controller: c,
                connection: connection,
                isReadAuthorityCurrent: () =>
                    activity.connectionFor(binding) != null,
                session: RemoteSession(
                    {'id': child.childSessionId!, 'title': child.goal}))));
  }

  Future<void> acknowledgeUnknown() async {
    final owner = c;
    final session = owner.current;
    final operation = owner.currentRun;
    if (session == null || operation == null) return;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Acknowledge unknown outcome?'),
                content: const Text(
                    'Prior work may already have had side effects. This marks the lost execution interrupted; it does not undo or repeat its work.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Keep checking')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Acknowledge'))
                ]));
    if (accepted == true &&
        mounted &&
        identical(c, owner) &&
        identical(owner.current, session) &&
        owner.sessions.contains(session) &&
        identical(owner.runs[session.id], operation)) {
      await owner.checkRunStatus(
          sessionId: session.id, acknowledgeUnknown: true);
    }
  }

  final composer = TextEditingController();
  final historySearch = TextEditingController();
  Timer? searchDebounce;
  String historyQuery = '';
  void searchHistory(String value) {
    searchDebounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() => historyQuery = '');
    } else {
      searchDebounce = Timer(const Duration(milliseconds: 200), () {
        if (mounted) setState(() => historyQuery = value);
      });
    }
  }

  final scroll = ScrollController();
  ChatController get c => widget.controller;
  @override
  void dispose() {
    activity.dispose();
    controlsUpdates?.cancel();
    revokeControls();
    c.removeListener(syncServers);
    for (final cache in serverCaches.values) {
      cache.dispose();
    }
    searchDebounce?.cancel();
    historySearch.dispose();
    WidgetsBinding.instance.removeObserver(this);
    c.pauseQueue(
        'Queue paused because the chat screen closed. Choose Resume when you return.',
        allSources: true);

    c.pauseRuns(true);
    composer.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> newChat() async {
    if (c.connections.isEmpty) {
      await Navigator.push(
          context,
          MaterialPageRoute<void>(
              builder: (_) => ConnectionsPage(controller: c)));
      if (!mounted || c.connections.isEmpty) return;
    }
    if (mounted) {
      await Navigator.push(context,
          MaterialPageRoute<void>(builder: (_) => NewChatPage(controller: c)));
    }
    if (mounted) setState(() => composer.clear());
  }

  Future<void> send() async {
    final text = composer.text.trim();
    if (c.submit(text)) {
      composer.clear();
    }
    if (mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients) {
          scroll.animateTo(scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut);
        }
      });
    }
  }

  Future<void> clear() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Delete this conversation?'),
                content: const Text(
                    'This removes the local history. It does not delete anything on your server.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Keep')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Delete'))
                ]));
    if (confirmed == true) {
      try {
        await c.clear();
        composer.clear();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not save the deletion.')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final session = c.current;
        final run = c.currentRun;
        final thinking = run == null
            ? c.busy
            : c.runPending &&
                (run.snapshot.state == RunState.queued ||
                    run.snapshot.state == RunState.running);
        final localMatches =
            searchLocalHistory(c.sessions.reversed, historyQuery);
        final names = c.connections
            .where((entry) => entry['id'] == session?.connectionId);
        final subtitle = session == null
            ? 'Your models. Your space.'
            : '${names.isEmpty ? 'Unavailable connection' : names.first['name']} · ${session.model}';
        return Scaffold(
          drawerEdgeDragWidth: 48,
          drawerEnableOpenDragGesture: true,
          onDrawerChanged: (open) {
            drawerOpen = open;
            if (open) syncServers();
          },
          appBar: AppBar(
              toolbarHeight: MediaQuery.textScalerOf(context).scale(32) + 24,
              titleSpacing: 0,
              title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        session == null || session.title.trim().isEmpty
                            ? 'New conversation'
                            : session.title,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text(subtitle,
                        style: const TextStyle(fontSize: 12, color: muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis)
                  ]),
              actions: [
                IconButton(
                    tooltip: 'New conversation',
                    onPressed: c.busy ? null : newChat,
                    icon: const Icon(Icons.add_rounded)),
                IconButton(
                    tooltip: 'Connection settings',
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                            builder: (_) => ConnectionsPage(controller: c))),
                    icon: const Icon(Icons.tune_rounded)),
                if (session != null)
                  IconButton(
                      tooltip: 'Delete conversation',
                      onPressed: c.busy ? null : clear,
                      icon: const Icon(Icons.delete_outline))
              ],
              bottom: const PreferredSize(
                  preferredSize: Size.fromHeight(1),
                  child: Divider(height: 1, color: Color(0xFFECEDE9)))),
          drawer: Drawer(
              child: SafeArea(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                if (MediaQuery.viewInsetsOf(context).bottom == 0)
                  const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Conversations',
                          style: TextStyle(
                              fontSize: 24, fontWeight: FontWeight.w600))),
                if (MediaQuery.viewInsetsOf(context).bottom == 0)
                  Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: FilledButton.icon(
                          onPressed: c.busy
                              ? null
                              : () {
                                  Navigator.pop(context);
                                  newChat();
                                },
                          icon: const Icon(Icons.add),
                          label: const Text('New conversation'))),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: TextField(
                    key: const Key('local-history-search'),
                    controller: historySearch,
                    onChanged: searchHistory,
                    decoration: InputDecoration(
                      labelText: 'Search local chats',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            historySearch.clear();
                            searchHistory('');
                          },
                          icon: const Icon(Icons.close)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                    child: ListView.builder(
                        itemCount: 2 +
                            (localMatches.isEmpty && historyQuery.isNotEmpty
                                ? 1
                                : localMatches.length) +
                            serverCaches.length,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return const ListTile(
                                title: Text('On this device'));
                          }
                          final localCount =
                              localMatches.isEmpty && historyQuery.isNotEmpty
                                  ? 1
                                  : localMatches.length;
                          if (index == 1 + localCount + serverCaches.length) {
                            return MediaQuery.viewInsetsOf(context).bottom == 0
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: Text(
                                        'Search stays on this device. History stays with its original connection and is not end-to-end encrypted.',
                                        style: TextStyle(color: muted)))
                                : const SizedBox.shrink();
                          }
                          if (index > localCount) {
                            final cache = serverCaches.values
                                .elementAt(index - localCount - 1);
                            return ConversationServer(
                                key: ObjectKey(cache.connection), cache: cache);
                          }
                          if (localMatches.isEmpty) {
                            return const ListTile(
                                title: Text('No matching conversations'));
                          }
                          final match = localMatches[index - 1];
                          final s = match.session;
                          return ListTile(
                              selected: s == session,
                              enabled: !c.busy,
                              title: Text(s.title,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                  match.snippet == null
                                      ? 'On this device · ${s.model}'
                                      : '${match.snippet}\nOn this device · ${s.model}',
                                  maxLines: match.snippet == null ? 1 : 3,
                                  overflow: TextOverflow.ellipsis),
                              onTap: () {
                                c.select(s);
                                composer.clear();
                                Navigator.pop(context);
                              });
                        })),
              ]))),
          body: c.loading
              ? const Center(child: CircularProgressIndicator())
              : Column(children: [
                  const UpdateAvailabilityBanner(),
                  Expanded(
                      child: session == null ||
                              session.messages.isEmpty &&
                                  c.pendingText == null &&
                                  !thinking &&
                                  !c.busy
                          ? Center(
                              child: SingleChildScrollView(
                                  padding: const EdgeInsets.all(32),
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.spa_outlined,
                                            size: 42, color: Color(0xFF3E6559)),
                                        const SizedBox(height: 22),
                                        const Text('A little space to think.',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                                fontSize: 27,
                                                fontWeight: FontWeight.w500)),
                                        const SizedBox(height: 12),
                                        Text(
                                            session == null
                                                ? 'Connect a model and begin a conversation.\nNothing is sent until you choose to send.'
                                                : 'What’s on your mind?',
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                                color: muted, height: 1.6)),
                                        if (session == null) ...[
                                          const SizedBox(height: 24),
                                          FilledButton(
                                              onPressed: newChat,
                                              child: Text(c.connections.isEmpty
                                                  ? 'Connect a model'
                                                  : 'New conversation'))
                                        ]
                                      ])))
                          : ListView(
                              controller: scroll,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 22, vertical: 24),
                              children: [
                                  for (var i = 0;
                                      i < session.messages.length;
                                      i++)
                                    MessageView(
                                        key: ValueKey('${session.id}-$i'),
                                        text: session.messages[i].content,
                                        user:
                                            session.messages[i].role == 'user'),
                                  if (c.pendingText != null)
                                    MessageView(
                                        text: c.pendingText!, user: true),
                                  if (thinking)
                                    const Padding(
                                        padding:
                                            EdgeInsets.symmetric(vertical: 18),
                                        child: BusyThinking(busy: true))
                                ])),
                  if (c.outbox.isNotEmpty ||
                      c.queueStatus != null ||
                      c.uncertainInput != null ||
                      c.readOnly ||
                      c.error != null ||
                      c.unsavedChanges)
                    Flexible(
                      child: ListView(
                          key: const Key('chat-feedback'),
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          children: [
                            if (c.outbox.isNotEmpty ||
                                c.queueStatus != null ||
                                c.uncertainInput != null)
                              const Text(
                                  'Queued · Kept only while Saathi stays open.',
                                  style: TextStyle(fontSize: 12)),
                            if (c.queueStatus != null) Text(c.queueStatus!),
                            if (c.canResumeQueue && c.queueStatus != null)
                              TextButton(
                                  onPressed: c.resumeQueue,
                                  child: const Text('Resume queue')),
                            if (c.uncertainInput != null)
                              SelectableText(
                                  'Not sent again: ${c.uncertainInput!.text}'),
                            if (c.uncertainInput != null)
                              TextButton(
                                child: const Text('Abandon held outbox'),
                                onPressed: () async {
                                  final source = c.uncertainInput!.session;
                                  final confirmed = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      scrollable: true,
                                      title: const Text(
                                          'Abandon unknown request?'),
                                      content: const Text(
                                          'The last request may have executed. Discarding the held outbox does not stop the server or prove there were no side effects. This removes the unknown input and ALL queued followers for this conversation only. Nothing will be resent, and completion is still unknown. You can instead keep this blocked and start a new conversation.'),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, false),
                                            child: const Text('Keep blocked')),
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, true),
                                            child: const Text('Abandon all')),
                                      ],
                                    ),
                                  );
                                  if (confirmed == true) {
                                    c.abandonHeldOutbox(source);
                                  }
                                },
                              ),
                            for (final item in c.outbox)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Queued'),
                                subtitle: Text(item.text,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                                trailing: TextButton(
                                    onPressed: () => c.cancelQueued(item),
                                    child: const Text('Cancel')),
                              ),
                            if (c.readOnly)
                              const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Text(
                                      'Read-only · This connection was removed or changed. Start a new conversation to send messages.')),
                            if (c.error != null)
                              Container(
                                  width: double.infinity,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .errorContainer,
                                  padding: const EdgeInsets.all(16),
                                  child: Text(c.error!,
                                      key: const Key('chat-error'),
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onErrorContainer))),
                            if (c.unsavedChanges)
                              TextButton.icon(
                                  onPressed: c.retrySave,
                                  icon: const Icon(Icons.save_outlined),
                                  label: const Text('Try saving again')),
                          ]),
                    ),
                  if (c.currentRun != null && c.runPending)
                    Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: !c.currentRun!.snapshot.terminal &&
                                c.currentRun!.snapshot.pendingControls
                                    .isNotEmpty
                            ? Row(children: [
                                Expanded(
                                    child: TextButton.icon(
                                        onPressed: reviewControls,
                                        icon: const Icon(Icons.pending_actions),
                                        label: Text(
                                            c.currentRun!.snapshot
                                                    .pendingControls
                                                    .any((p) =>
                                                        p['kind'] == 'approval')
                                                ? 'Review action'
                                                : 'Answer needed',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis))),
                                IconButton(
                                    tooltip: 'Check status',
                                    onPressed: c.busy
                                        ? null
                                        : () => c.checkRunStatus(),
                                    icon: const Icon(Icons.refresh)),
                              ])
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                    Row(children: [
                                      Expanded(
                                          child: Text(
                                              'Run: ${c.currentRun!.snapshot.status}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis)),
                                      if (c.currentRun!.runId == null)
                                        TextButton(
                                            onPressed: c.busy
                                                ? null
                                                : () => c.checkRunStatus(),
                                            child: const Text('Reconnect'))
                                      else
                                        IconButton(
                                            tooltip: 'Check status',
                                            onPressed: c.busy
                                                ? null
                                                : () => c.checkRunStatus(),
                                            icon: const Icon(Icons.refresh)),
                                    ]),
                                    if (c.currentRun!.snapshot.status ==
                                            'unknown' &&
                                        c.currentRun!.runId != null)
                                      TextButton(
                                          onPressed: c.busy
                                              ? null
                                              : acknowledgeUnknown,
                                          child: const Text(
                                              'Acknowledge unknown outcome')),
                                  ])),
                  SafeArea(
                      top: false,
                      child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            AgentActivityStrip(
                                model: activity.model,
                                onOpenParent: openActivityParent,
                                onOpenChildHistory: openActivityChild),
                            Container(
                                padding: const EdgeInsets.fromLTRB(15, 4, 5, 4),
                                decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(26),
                                    border: Border.all(
                                        color: const Color(0xFFDDE3DE))),
                                child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Expanded(
                                          child: TextField(
                                              key: const Key('composer'),
                                              controller: composer,
                                              enabled: session != null &&
                                                  !c.unsavedChanges &&
                                                  !c.readOnly &&
                                                  !c.changingConnection,
                                              minLines: 1,
                                              maxLines: MediaQuery.viewInsetsOf(
                                                              context)
                                                          .bottom >
                                                      0
                                                  ? 2
                                                  : 6,
                                              textCapitalization:
                                                  TextCapitalization.sentences,
                                              onChanged: (_) => setState(() {}),
                                              decoration: const InputDecoration(
                                                  hintText: 'Message Saathi',
                                                  border: InputBorder.none))),
                                      IconButton.filled(
                                          tooltip: 'Send',
                                          onPressed: c.readOnly ||
                                                  c.changingConnection ||
                                                  session == null ||
                                                  c.unsavedChanges ||
                                                  c.queueStatus != null ||
                                                  composer.text.trim().isEmpty
                                              ? null
                                              : send,
                                          icon: const Icon(
                                              Icons.arrow_upward_rounded))
                                    ])),
                            if (MediaQuery.viewInsetsOf(context).bottom ==
                                0) ...[
                              Align(
                                  alignment: Alignment.centerLeft,
                                  child: PromptOptimizer(
                                      key: ValueKey(session?.id),
                                      controller: c,
                                      composer: composer)),
                              const SizedBox(height: 8),
                              const Text(
                                  'AI can make mistakes. Review important details.',
                                  style: TextStyle(fontSize: 11, color: muted))
                            ],
                          ]))),
                ]),
        );
      });
}

class MessageView extends StatefulWidget {
  const MessageView({super.key, required this.text, required this.user});
  final String text;
  final bool user;
  @override
  State<MessageView> createState() => _MessageViewState();
}

class _MessageViewState extends State<MessageView> {
  bool activity = false;
  Future<void> copyMessage() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.text));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Copied')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not copy this message.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: copyMessage,
      onHorizontalDragEnd:
          widget.user ? null : (_) => setState(() => activity = !activity),
      child: Padding(
          padding: const EdgeInsets.only(bottom: 28),
          child: Align(
              alignment:
                  widget.user ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                  constraints: const BoxConstraints(maxWidth: 720),
                  padding: widget.user
                      ? const EdgeInsets.symmetric(horizontal: 18, vertical: 14)
                      : EdgeInsets.zero,
                  decoration: widget.user
                      ? BoxDecoration(
                          color: const Color(0xFFE3EBE6),
                          borderRadius: BorderRadius.circular(20))
                      : null,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!widget.user) ...[
                          const Text('Saathi',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF3E6559))),
                          const SizedBox(height: 10)
                        ],
                        if (widget.user)
                          Text(widget.text,
                              style:
                                  const TextStyle(fontSize: 17, height: 1.45))
                        else
                          MarkdownBody(
                              data: widget.text,
                              imageBuilder: safeMarkdownImageBuilder,
                              selectable: false,
                              styleSheet: MarkdownStyleSheet(
                                  p: const TextStyle(
                                      fontSize: 18, height: 1.5))),
                        if (activity && !widget.user)
                          const Padding(
                              padding: EdgeInsets.only(top: 14),
                              child: Text(
                                  'Activity · Response received\nOnly observable status is shown. No private reasoning.',
                                  style: TextStyle(fontSize: 12, color: muted)))
                      ])))));
}
