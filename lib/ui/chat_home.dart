import 'dart:async';

import 'canonical_connection.dart';
import 'canonical_controls.dart';
import 'adaptive_chat_shell.dart';
import 'chat_settings_panel.dart';

import '../chat_organization/organization.dart';
import '../chat_organization/organization_widgets.dart';
import '../chat_organization/reply_visibility.dart';
import '../chat_organization/reported_usage.dart';
import '../agent_activity/activity_owner.dart';
import '../agent_activity/activity_strip.dart';
import '../agent_activity/activity_model.dart';
import '../core/saathi_core.dart' show RemoteSession;
import 'remote_sessions.dart';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/semantics.dart';

import 'transcript_latest.dart';
import 'local_history_search.dart';
import 'transcript_presentation.dart';
import '../update_host.dart';

import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../agent_controls/agent_controls.dart';
import '../agent_controls/agent_controls_panel.dart';
import 'chat_controller.dart';
import 'busy_thinking.dart';
import 'connections.dart';
import 'safe_markdown.dart';
import 'markdown_theme.dart';
import 'conversation_servers.dart';
import 'prompt_optimizer.dart';
import 'growing_message_input.dart';

class ChatHome extends StatefulWidget {
  const ChatHome({
    super.key,
    required this.controller,
  });
  final ChatController controller;
  @override
  State<ChatHome> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<ChatHome> with WidgetsBindingObserver {
  late ActivityOwner activity;
  bool drawerOpen = false, drawerDragging = false, archivedView = false;
  bool desktopSettings = false;
  ChatSession? settingsSession;
  bool wideNavigation = false;
  final chatScaffoldKey = GlobalKey<ScaffoldState>();
  final chatSettingsKey = GlobalKey();
  Timer? drawerGestureTimer;

  void startDrawerGesture() {
    drawerGestureTimer?.cancel();
    if (!drawerDragging) setState(() => drawerDragging = true);
  }

  void endDrawerGesture() {
    drawerGestureTimer?.cancel();
    drawerGestureTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => drawerDragging = false);
    });
  }

  Future<void> editConversation(ChatSession session) => showConversationEdit(
        context: context,
        organization: c.organization,
        identity: c.identityOf(session),
        fallbackInstructions: session.systemPrompt,
        policy: c.personaPolicy,
        pendingReason: c.pendingPersonaReason,
      );
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
        isOwnerCurrent: () => mounted && identical(owner, controlsOwner),
      );
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
                    controller: controller,
                    redact: controller.redact,
                  )
                : const Center(child: Text('Request no longer available.')),
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not open requests. Check status and try again.',
            ),
          ),
        );
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
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    c.pauseRuns(
      lifecycle != AppLifecycleState.resumed,
      pauseCatalog:
          lifecycle != null && lifecycle != AppLifecycleState.detached,
    );
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
          !identical(
            event.connectionRevision,
            controller.boundary.scope.authorityToken,
          )) {
        return;
      }
      try {
        controller.updateSnapshot(
          PendingControlsSnapshot.fromJson(
            controller.boundary.scope,
            event.snapshot.data,
          ),
        );
        // The normal poll is authoritative; never issue another poll from it.
      } catch (_) {
        /* The next explicit refresh reports malformed status. */
      }
    });
  }

  String? shownStream;
  bool followStream = false;
  int scrollRevision = 0;
  ChatController? shownOwner;
  int? shownSelection;
  final Map<ConversationIdentity, String> _drafts = {};
  ConversationIdentity? _draftOwner;
  final GlobalKey<TooltipState> _sendTooltipKey = GlobalKey<TooltipState>();

  void _saveCurrentDraft() {
    final owner = _draftOwner;
    if (owner == null) return;
    if (composer.text.isEmpty) {
      _drafts.remove(owner);
    } else {
      _drafts[owner] = composer.text;
    }
  }

  final _messageKeys = <(String, String), GlobalKey>{};
  List<String> _shownMessageIds = [];
  GlobalKey messageKey(ChatSession session, int index) =>
      _messageKeys.putIfAbsent(
          (session.id, session.messages[index].id ?? 'index-$index'),
          GlobalKey.new);

  void preserveTranscriptAnchor(bool selectionChanged,
      {bool layoutChanged = false}) {
    final session = c.current;
    final ids = [
      for (var i = 0; i < (session?.messages.length ?? 0); i++)
        session!.messages[i].id ?? 'index-$i'
    ];
    final changed = ids.length != _shownMessageIds.length ||
        List.generate(ids.length, (i) => i).any((i) =>
            i >= _shownMessageIds.length || ids[i] != _shownMessageIds[i]);
    _shownMessageIds = ids;
    if (selectionChanged) {
      _messageKeys.clear();
      return;
    }
    if ((!changed && !layoutChanged) ||
        session == null ||
        !scroll.hasClients ||
        scroll.position.extentAfter < 120) {
      return;
    }
    final position = scroll.position;
    final after = position.extentAfter;
    GlobalKey? anchor;
    double? top;
    final viewport = position.context.notificationContext?.findRenderObject();
    if (viewport is! RenderBox) return;
    final viewTop = viewport.localToGlobal(Offset.zero).dy;
    for (final id in ids) {
      final key = _messageKeys[(session.id, id)];
      final box = key?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final y = box.localToGlobal(Offset.zero).dy;
      if (y + box.size.height > viewTop &&
          y < viewTop + viewport.size.height &&
          (top == null || y < top)) {
        anchor = key;
        top = y;
      }
    }
    if (anchor == null || top == null) return;
    // Prefix compaction can move a lazily built anchor offscreen. Restore its
    // distance from the trailing history first, then correct to its exact row.
    followStream = false;
    final revision = ++scrollRevision;
    final selection = c.selectionGeneration;
    final owner = c;
    bool valid() =>
        mounted &&
        identical(c, owner) &&
        identical(c.current, session) &&
        selection == c.selectionGeneration &&
        revision == scrollRevision &&
        scroll.hasClients &&
        identical(scroll.position, position);
    var attempt = 0;
    void restore(Duration _) {
      if (!valid()) return;
      final box = anchor!.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) {
        position.jumpTo((position.maxScrollExtent - after)
            .clamp(position.minScrollExtent, position.maxScrollExtent));
      } else {
        final delta = box.localToGlobal(Offset.zero).dy - top!;
        if (delta.abs() <= 1) return;
        position.jumpTo((position.pixels + delta)
            .clamp(position.minScrollExtent, position.maxScrollExtent));
      }
      if (++attempt < 4) {
        WidgetsBinding.instance.addPostFrameCallback(restore);
        WidgetsBinding.instance.scheduleFrame();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback(restore);
  }

  void setChatSettings(ChatSession? session) {
    preserveTranscriptAnchor(false, layoutChanged: true);
    setState(() => settingsSession = session);
  }

  void followOutput({bool newInput = false}) {
    if (!scroll.hasClients || !followStream) return;
    final owner = c;
    final session = owner.current;
    final selection = owner.selectionGeneration;
    final operation = owner.currentRun;
    final connection = owner.connections
        .where((connection) => connection['id'] == session?.connectionId)
        .firstOrNull;
    final position = scroll.position;
    final revision = scrollRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Layout may grow the live edge, but neither a reader gesture nor a
      // source/selection change may transfer this frame's follow permission.
      if (!mounted ||
          !identical(c, owner) ||
          owner.selectionGeneration != selection ||
          !identical(owner.current, session) ||
          (!newInput && !identical(owner.currentRun, operation)) ||
          connection == null ||
          !owner.isCurrentConnection(connection) ||
          !scroll.hasClients ||
          !identical(scroll.position, position) ||
          !followStream ||
          revision != scrollRevision ||
          position.userScrollDirection != ScrollDirection.idle) {
        return;
      }
      if (newInput) {
        unawaited(
          position.animateTo(
            position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          ),
        );
      } else {
        position.jumpTo(position.maxScrollExtent);
      }
    });
  }

  void syncServers() {
    // Revoke pending scrolling at mutation start, even if the source returns
    // to the same identity (including missing -> present -> missing).
    if (c.changingConnection) scrollRevision++;
    final selectionChanged =
        !identical(shownOwner, c) || shownSelection != c.selectionGeneration;
    preserveTranscriptAnchor(selectionChanged);
    if (selectionChanged) {
      desktopSettings = false;
      settingsSession = null;
      final nextSession = c.current;
      final nextIdentity =
          nextSession == null ? null : c.identityOf(nextSession);
      if (shownOwner != null) {
        if (identical(shownOwner, c)) {
          _saveCurrentDraft();
        } else {
          _drafts.clear();
          _draftOwner = null;
        }
        final restored =
            nextIdentity == null ? '' : (_drafts[nextIdentity] ?? '');
        composer.value = TextEditingValue(
          text: restored,
          selection: TextSelection.collapsed(offset: restored.length),
        );
      }
      _draftOwner = nextIdentity;
      shownOwner = c;
      shownSelection = c.selectionGeneration;
      followStream = false;
    }
    final text = c.streamingText;
    if (shownStream != text) {
      shownStream = text;
      // Follow real output only while the reader is already at the live edge.
      // Never pull someone away from older history or change composer focus.
      if (!selectionChanged &&
          scroll.hasClients &&
          (followStream || scroll.position.extentAfter < 120)) {
        followStream = true;
        followOutput();
      }
    }
    if (controls != null && !controls!.isCurrent) revokeControls();
    for (final connection in serverCaches.keys.toList()) {
      if (!c.isCurrentConnection(connection)) {
        serverCaches.remove(connection)!.dispose();
      }
    }
    for (final connection in c.connections.where(
      (c) => c['type'] == 'hermes',
    )) {
      final cache = serverCaches.putIfAbsent(
        connection,
        () => ConversationServerCache(c, connection),
      );
      if ((drawerOpen || wideNavigation) && !cache.loaded && !cache.loading) {
        cache.load();
      }
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
      c.select(session);
    });
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
          isReadAuthorityCurrent: () => activity.connectionFor(binding) != null,
          session: RemoteSession({
            'id': child.childSessionId!,
            'title': child.goal,
          }),
        ),
      ),
    );
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
          'Prior work may already have had side effects. This marks the lost execution interrupted; it does not undo or repeat its work.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep checking'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Acknowledge'),
          ),
        ],
      ),
    );
    if (accepted == true &&
        mounted &&
        identical(c, owner) &&
        identical(owner.current, session) &&
        owner.sessions.contains(session) &&
        identical(owner.runs[session.id], operation)) {
      await owner.checkRunStatus(
        sessionId: session.id,
        acknowledgeUnknown: true,
      );
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

  // Lazy rows can revise the estimated edge after each layout. Corrections
  // belong to this activation only, never to an unbounded stream of updates.
  void jumpToLatest() {
    if (!scroll.hasClients) return;
    final owner = c;
    final session = owner.current;
    final selection = owner.selectionGeneration;
    final connection = owner.connections
        .where((connection) => connection['id'] == session?.connectionId)
        .firstOrNull;
    final position = scroll.position;
    final revision = ++scrollRevision;
    // A fixed budget based on the captured rows cannot grow with streaming.
    var remaining = (session?.messages.length ?? 0) + 3;
    bool valid() =>
        mounted &&
        identical(c, owner) &&
        identical(owner.current, session) &&
        owner.selectionGeneration == selection &&
        (connection == null
            ? !owner.connections
                .any((connection) => connection['id'] == session?.connectionId)
            : owner.isCurrentConnection(connection)) &&
        scroll.hasClients &&
        identical(scroll.position, position) &&
        scrollRevision == revision;
    void correct(Duration _) {
      if (!valid() || position.extentAfter <= 1 || remaining-- <= 0) return;
      position.jumpTo(position.maxScrollExtent);
      WidgetsBinding.instance.addPostFrameCallback(correct);
      WidgetsBinding.instance.scheduleFrame();
    }

    followStream = true;
    // Immediate motion also respects the reduced-animation preference.
    position.jumpTo(position.maxScrollExtent);
    WidgetsBinding.instance.addPostFrameCallback(correct);
    WidgetsBinding.instance.scheduleFrame();
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
    drawerGestureTimer?.cancel();
    historySearch.dispose();
    WidgetsBinding.instance.removeObserver(this);
    c.pauseQueue(
      'Queue paused because the chat screen closed. Choose Resume when you return.',
      allSources: true,
    );

    c.pauseRuns(true);
    composer.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> newChat() async {
    if (c.connections.isEmpty) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => ConnectionsPage(controller: c)),
      );
      if (!mounted || c.connections.isEmpty) return;
    }
    if (mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => NewChatPage(controller: c)),
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> send() async {
    final text = composer.text.trim();
    if (c.submit(text)) {
      followStream = true;
      if (_draftOwner != null) _drafts.remove(_draftOwner);
      composer.clear();
      followOutput(newInput: true);
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this conversation?'),
        content: const Text(
          'This removes the local history. It does not delete anything on your server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final deleted = c.current == null ? null : c.identityOf(c.current!);
      try {
        await c.clear();
        final currentIdentity =
            c.current == null ? null : c.identityOf(c.current!);
        if (deleted != null && deleted != currentIdentity) {
          _drafts.remove(deleted);
        }
        if (mounted && c.current == null) {
          _draftOwner = null;
          composer.clear();
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not save the deletion.')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: buildWorkspace);

  Widget buildWorkspace(BuildContext context, BoxConstraints constraints) =>
      ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final session = c.current;
          final wide = AdaptiveChatShell.fits(context, constraints.maxWidth);
          if (wideNavigation != wide) {
            wideNavigation = wide;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) syncServers();
            });
          }
          final thinking = c.showPendingThinking;
          final localMatches = searchLocalHistory(
            c.orderedSessions().where(
                  (s) =>
                      c.organization.entry(c.identityOf(s)).archived ==
                      archivedView,
                ),
            historyQuery,
            displayTitle: c.displayTitle,
          );
          final archived = c.sessions
              .where((s) => c.organization.entry(c.identityOf(s)).archived)
              .toList();
          final archivedAttention = archived
              .where(
                (s) =>
                    c.organization.entry(c.identityOf(s)).unread ||
                    c.workState(s) != ConversationWorkState.idle,
              )
              .length;
          final names = c.connections.where(
            (entry) => entry['id'] == session?.connectionId,
          );
          final subtitle = session == null
              ? 'Your models. Your space.'
              : '${names.isEmpty ? 'Unavailable connection' : names.first['name']} · ${c.replyModel(session)}';
          return Listener(
            onPointerDown: (event) {
              if (!wide && event.position.dx <= 48) startDrawerGesture();
            },
            onPointerUp: (_) => endDrawerGesture(),
            onPointerCancel: (_) => endDrawerGesture(),
            child: AdaptiveChatShell(
              wide: wide,
              scaffoldKey: chatScaffoldKey,
              showSettings: desktopSettings,
              onSettingsChanged: (value) {
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() => desktopSettings = value);
              },
              // Capture conversation scope when Settings is entered, not when
              // the persistent desktop shell first mounts its inactive panes.
              settings: desktopSettings
                  ? ConnectionsPage(controller: c, embedded: true)
                  : const SizedBox.shrink(),
              chatSettings:
                  settingsSession != null && identical(settingsSession, session)
                      ? ChatSettingsPanel(
                          key: chatSettingsKey,
                          controller: c,
                          session: session!,
                          onClose: () => setChatSettings(null),
                        )
                      : null,
              onDrawerChanged: (open) {
                setState(() {
                  drawerOpen = open;
                  drawerDragging = false;
                });
                if (open) syncServers();
              },
              appBar: AppBar(
                automaticallyImplyLeading: !wide,
                leading: wide
                    ? null
                    : Builder(
                        builder: (context) => IconButton(
                          tooltip: 'Open navigation menu',
                          icon: const Icon(Icons.menu),
                          onPressed: () {
                            setState(() => drawerOpen = true);
                            Scaffold.of(context).openDrawer();
                          },
                        ),
                      ),
                toolbarHeight: MediaQuery.textScalerOf(context).scale(32) + 24,
                titleSpacing: wide ? 24 : 0,
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session == null || c.displayTitle(session).trim().isEmpty
                          ? 'New conversation'
                          : c.displayTitle(session),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                actions: [
                  if (wide &&
                      session != null &&
                      {
                        TargetPlatform.linux,
                        TargetPlatform.macOS,
                        TargetPlatform.windows
                      }.contains(Theme.of(context).platform))
                    TextFieldTapRegion(
                      child: IconButton(
                        tooltip: 'Chat settings',
                        onPressed: () => setChatSettings(session),
                        icon: const Icon(Icons.tune_rounded),
                      ),
                    ),
                  if (!wide)
                    IconButton(
                      tooltip: 'New conversation',
                      onPressed: c.busy ? null : newChat,
                      icon: const Icon(Icons.add_rounded),
                    ),
                  if (!wide)
                    IconButton(
                      tooltip: 'Settings',
                      constraints:
                          const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ConnectionsPage(controller: c),
                        ),
                      ),
                      icon: const Icon(Icons.tune_rounded),
                    ),
                  if (session != null)
                    IconButton(
                      tooltip: 'Delete conversation',
                      onPressed: c.canDeleteConversation ? clear : null,
                      icon: const Icon(Icons.delete_outline),
                    ),
                ],
                bottom: const PreferredSize(
                  preferredSize: Size.fromHeight(1),
                  child: Divider(height: 1),
                ),
              ),
              sidebar: Drawer(
                elevation: wide ? 0 : null,
                shape: wide ? const RoundedRectangleBorder() : null,
                backgroundColor: wide
                    ? Theme.of(context).colorScheme.surfaceContainerLow
                    : null,
                child: SafeArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (MediaQuery.viewInsetsOf(context).bottom == 0)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Conversations',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (MediaQuery.viewInsetsOf(context).bottom == 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: FilledButton.icon(
                            onPressed: c.busy
                                ? null
                                : () {
                                    if (!wide) Navigator.pop(context);
                                    setState(() => desktopSettings = false);
                                    newChat();
                                  },
                            icon: const Icon(Icons.add),
                            label: const Text('New conversation'),
                          ),
                        ),
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
                              icon: const Icon(Icons.close),
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                        key: const Key('archived-view'),
                        onPressed: () =>
                            setState(() => archivedView = !archivedView),
                        child: Text(
                          archivedView
                              ? 'Back to recent conversations'
                              : 'Archived (${archived.length}${archivedAttention > 0 ? ', $archivedAttention need attention' : ''})',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: 3 +
                              (localMatches.isEmpty && historyQuery.isNotEmpty
                                  ? 1
                                  : localMatches.length) +
                              serverCaches.length,
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return ListTile(
                                title: Text(
                                  archivedView
                                      ? 'Archived on this device'
                                      : 'On this device',
                                ),
                              );
                            }
                            final localCount =
                                localMatches.isEmpty && historyQuery.isNotEmpty
                                    ? 1
                                    : localMatches.length;
                            if (index == 1 + localCount + serverCaches.length) {
                              return ListTile(
                                leading: const Icon(Icons.link),
                                title: const Text('Hermes Desktop / CLI'),
                                onTap: () {
                                  if (!wide) Navigator.pop(context);
                                  Navigator.push(
                                    context,
                                    CanonicalConnectionRoute<void>(
                                      builder: (_) => CanonicalConnectionPage(
                                          controller: c),
                                    ),
                                  );
                                },
                              );
                            }
                            if (index == 2 + localCount + serverCaches.length) {
                              return MediaQuery.viewInsetsOf(context).bottom ==
                                      0
                                  ? Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Text(
                                        'Search stays on this device. History stays with its original connection and is not end-to-end encrypted.',
                                        style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant),
                                      ),
                                    )
                                  : const SizedBox.shrink();
                            }
                            if (index > localCount) {
                              final cache = serverCaches.values.elementAt(
                                index - localCount - 1,
                              );
                              return ConversationServer(
                                key: ObjectKey(cache.connection),
                                cache: cache,
                                closeDrawerOnOpen: !wide,
                              );
                            }
                            if (localMatches.isEmpty) {
                              return const ListTile(
                                title: Text('No matching conversations'),
                              );
                            }
                            final match = localMatches[index - 1];
                            final s = match.session;
                            final sessionReadOnly = c.isSessionReadOnly(s);
                            return ConversationActionRow(
                              key: ValueKey(c.identityOf(s).storageKey),
                              selected: wide && identical(s, session),
                              readOnly: sessionReadOnly,
                              row: ConversationRowData(
                                identity: c.identityOf(s),
                                title: s.title,
                                subtitle: match.snippet == null
                                    ? 'On this device · ${s.model}'
                                    : '${match.snippet}\nOn this device · ${s.model}',
                                state: c.workState(s),
                                readOnly: sessionReadOnly,
                                latestMessageAt: s.latestMessageAt,
                              ),
                              presentation:
                                  c.organization.entry(c.identityOf(s)),
                              onEdit: () => editConversation(s),
                              onArchive: () async {
                                try {
                                  await c.organization.setArchived(
                                    c.identityOf(s),
                                    !c.organization
                                        .entry(c.identityOf(s))
                                        .archived,
                                  );
                                } catch (_) {
                                  /* Save-first metadata error is shown below. */
                                }
                              },
                              onSelect: () {
                                c.select(s);
                                if (!wide) Navigator.pop(context);
                                setState(() => desktopSettings = false);
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              body: c.loading
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      children: [
                        const UpdateAvailabilityBanner(),
                        Expanded(
                          child: LayoutBuilder(
                            // Use the space left after the composer and run controls,
                            // so feedback cannot push them beyond the usable screen.
                            builder: (_, constraints) => Column(
                              children: [
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
                                                Icon(
                                                  Icons.spa_outlined,
                                                  size: 42,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary,
                                                ),
                                                const SizedBox(height: 22),
                                                const Text(
                                                  'A little space to think.',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    fontSize: 27,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                                const SizedBox(height: 12),
                                                Text(
                                                  session == null
                                                      ? 'Connect a model and begin a conversation.\nNothing is sent until you choose to send.'
                                                      : 'What’s on your mind?',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                    height: 1.6,
                                                  ),
                                                ),
                                                if (session == null) ...[
                                                  const SizedBox(height: 24),
                                                  FilledButton(
                                                    onPressed: newChat,
                                                    child: Text(
                                                      c.connections.isEmpty
                                                          ? 'Connect a model'
                                                          : 'New conversation',
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        )
                                      : TranscriptLatest(
                                          key: ValueKey(
                                              (c, c.selectionGeneration)),
                                          controller: scroll,
                                          onJump: jumpToLatest,
                                          onReaderInteraction: () {
                                            scrollRevision++;
                                            followStream =
                                                scroll.position.extentAfter <
                                                    120;
                                          },
                                          onUpdate: (event) {
                                            if (event.dragDetails != null ||
                                                scroll.position
                                                        .userScrollDirection !=
                                                    ScrollDirection.idle) {
                                              scrollRevision++;
                                              followStream =
                                                  event.metrics.extentAfter <
                                                      120;
                                            }
                                            return false;
                                          },
                                          child: ListView(
                                            controller: scroll,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 22,
                                              vertical: 24,
                                            ),
                                            children: [
                                              for (var i = 0;
                                                  i < session.messages.length;
                                                  i++)
                                                if (showsHistoryBubble(
                                                    session.messages[i]))
                                                  KeyedSubtree(
                                                    key: messageKey(session, i),
                                                    child: MessageView(
                                                      key: ValueKey(
                                                          '${session.id}-$i'),
                                                      activityText:
                                                          precedingHistoryActivity(
                                                              session.messages,
                                                              i),
                                                      text: session
                                                          .messages[i].content,
                                                      user: session.messages[i]
                                                              .role ==
                                                          'user',
                                                      usage: ReportedUsage
                                                          .fromMetadata(
                                                        session.messages[i]
                                                            .metadata,
                                                      ),
                                                      contextMetadata:
                                                          ConversationContextMetadata(
                                                        serverOwned: c
                                                                .personaPolicy(
                                                              c.identityOf(
                                                                  session),
                                                            ) ==
                                                            PersonaEditPolicy
                                                                .serverOwned,
                                                        retainedMessages:
                                                            session.messages
                                                                .length,
                                                      ),
                                                      answerBuilder: (body) =>
                                                          ForegroundReplyVisibility(
                                                        key: ValueKey((
                                                          c.identityOf(session),
                                                          session
                                                              .messages[i].id,
                                                        )),
                                                        replyIdentity: (
                                                          c.identityOf(session),
                                                          session
                                                              .messages[i].id,
                                                        ),
                                                        enabled: !(wide &&
                                                                desktopSettings) &&
                                                            !(drawerOpen &&
                                                                !wide) &&
                                                            !drawerDragging &&
                                                            identical(
                                                              c.current,
                                                              session,
                                                            ) &&
                                                            session.messages[i]
                                                                    .id !=
                                                                null &&
                                                            c.organization
                                                                        .entry(
                                                                          c.identityOf(
                                                                            session,
                                                                          ),
                                                                        )
                                                                        .completions[
                                                                    session
                                                                        .messages[
                                                                            i]
                                                                        .id] ==
                                                                false,
                                                        onVisible: () =>
                                                            c.replyVisible(
                                                          session,
                                                          session
                                                              .messages[i].id!,
                                                        ),
                                                        child: body,
                                                      ),
                                                    ),
                                                  ),
                                              if (c.pendingText != null)
                                                MessageView(
                                                  text: c.pendingText!,
                                                  user: true,
                                                  pending: true,
                                                ),
                                              // Keep the active response at the
                                              // live edge, even with tall queued
                                              // follow-ups in the transcript.
                                              for (final item in c.outbox)
                                                MessageView(
                                                  key: ValueKey(item.replyId),
                                                  text: item.text,
                                                  user: true,
                                                  pending: true,
                                                  onCancelPending: () =>
                                                      c.cancelQueued(item),
                                                ),
                                              if (c.streamingText?.isNotEmpty ??
                                                  false)
                                                MessageView(
                                                  text: c.streamingText!,
                                                  user: false,
                                                ),
                                              if (thinking &&
                                                  (c.streamingText?.isEmpty ??
                                                      true))
                                                Padding(
                                                  padding: EdgeInsets.symmetric(
                                                    vertical: 18,
                                                  ),
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      const BusyThinking(
                                                          busy: true),
                                                      if (defaultTargetPlatform !=
                                                              TargetPlatform
                                                                  .android ||
                                                          c.runObservationProblem !=
                                                              null)
                                                        Text(c.pendingStatus,
                                                            key: const Key(
                                                                'pending-status')),
                                                      if (c.reportedActivity !=
                                                              null &&
                                                          c.runObservationProblem ==
                                                              null)
                                                        Text(
                                                            c.reportedActivity!,
                                                            key: const Key(
                                                                'reported-activity')),
                                                    ],
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                ),
                                if (c.queueStatus != null ||
                                    c.uncertainInput != null ||
                                    c.readOnly ||
                                    c.error != null ||
                                    c.runObservationProblem != null ||
                                    c.unsavedChanges ||
                                    c.organizationProblem != null ||
                                    c.canonical != null)
                                  ConstrainedBox(
                                    // Feedback scrolls within a bounded share of the body;
                                    // short feedback gives its unused space to the transcript.
                                    constraints: BoxConstraints(
                                      maxHeight: constraints.maxHeight * .5,
                                    ),
                                    child: ListView(
                                      key: const Key('chat-feedback'),
                                      shrinkWrap: true,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                      ),
                                      children: [
                                        if (c.canonical != null)
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 16),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    (c.canonical!.reconciling
                                                            ? c.canonical!
                                                                .pendingStatus
                                                            : c.canonical!
                                                                .problem) ??
                                                        (c.runPending
                                                            ? c.canonical!
                                                                .pendingStatus
                                                            : 'Attached to Hermes'),
                                                  ),
                                                ),
                                                IconButton(
                                                  tooltip:
                                                      'Resync Hermes session',
                                                  icon: const Icon(Icons.sync),
                                                  onPressed: c.refreshCanonical,
                                                ),
                                              ],
                                            ),
                                          ),
                                        if (c.queueStatus != null)
                                          Text(c.queueStatus!),
                                        if (c.canResumeQueue &&
                                            c.queueStatus != null)
                                          TextButton(
                                            onPressed: c.resumeQueue,
                                            child: const Text('Resume queue'),
                                          ),
                                        if (c.uncertainInput != null)
                                          SelectableText(
                                            'Not sent again: ${c.uncertainInput!.text}',
                                          ),
                                        if (c.uncertainInput != null)
                                          TextButton(
                                            child: const Text(
                                              'Abandon held outbox',
                                            ),
                                            onPressed: () async {
                                              final source =
                                                  c.uncertainInput!.session;
                                              final confirmed =
                                                  await showDialog<bool>(
                                                context: context,
                                                builder: (context) =>
                                                    AlertDialog(
                                                  scrollable: true,
                                                  title: const Text(
                                                    'Discard held recovery input?',
                                                  ),
                                                  content: const Text(
                                                    'This removes the retained input and ALL queued followers for this conversation only. Nothing will be resent. If a request was dispatched, it may have executed: discarding does not stop the server or establish its outcome. You can instead keep this blocked and start a new conversation.',
                                                  ),
                                                  actions: [
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                        context,
                                                        false,
                                                      ),
                                                      child: const Text(
                                                        'Keep blocked',
                                                      ),
                                                    ),
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                        context,
                                                        true,
                                                      ),
                                                      child: const Text(
                                                        'Abandon all',
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              );
                                              if (confirmed == true) {
                                                await c
                                                    .abandonHeldOutbox(source);
                                              }
                                            },
                                          ),
                                        if (c.readOnly &&
                                            names.firstOrNull?['type'] ==
                                                'hermesGateway') ...[
                                          Padding(
                                            padding: const EdgeInsets.all(16),
                                            child: Text(session
                                                        ?.canonicalProfileId ==
                                                    null
                                                ? 'This saved conversation has no verified host profile. Connect through Hermes Desktop / CLI and select the authorized session. Its old history will not be reassigned.'
                                                : 'Reconnect to this conversation’s original Hermes host with a fresh invite. Nothing will be resent.'),
                                          ),
                                          if (session?.canonicalProfileId !=
                                              null)
                                            TextButton(
                                              onPressed: !c.canChangeConnections
                                                  ? null
                                                  : () => Navigator.push(
                                                        context,
                                                        CanonicalConnectionRoute<
                                                                void>(
                                                            builder: (_) =>
                                                                CanonicalConnectionPage(
                                                                  controller: c,
                                                                  connection:
                                                                      names
                                                                          .first,
                                                                  targetSession:
                                                                      session,
                                                                )),
                                                      ),
                                              child: const Text(
                                                  'Reconnect to original host'),
                                            ),
                                        ] else if (c.readOnly)
                                          const Padding(
                                            padding: EdgeInsets.all(16),
                                            child: Text(
                                              'Read-only · This connection was removed or changed. Start a new conversation to send messages.',
                                            ),
                                          ),
                                        if (c.runObservationProblem != null)
                                          Text(c.runObservationProblem!),
                                        if (c.organizationProblem != null) ...[
                                          Text(c.organizationProblem!),
                                          TextButton(
                                            onPressed: c.organization.saving
                                                ? null
                                                : c.retryOrganizationSave,
                                            child: const Text(
                                              'Try saving details again',
                                            ),
                                          ),
                                        ],
                                        if (c.error != null)
                                          Container(
                                            width: double.infinity,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .errorContainer,
                                            padding: const EdgeInsets.all(16),
                                            child: Text(
                                              c.error!,
                                              key: const Key('chat-error'),
                                              style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onErrorContainer,
                                              ),
                                            ),
                                          ),
                                        if (c.unsavedChanges)
                                          TextButton.icon(
                                            onPressed: c.retrySave,
                                            icon:
                                                const Icon(Icons.save_outlined),
                                            label:
                                                const Text('Try saving again'),
                                          ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (c.currentRun != null && c.runPending)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: !c.currentRun!.snapshot.terminal &&
                                    c.currentRun!.snapshot.pendingControls
                                        .isNotEmpty
                                ? Row(
                                    children: [
                                      Expanded(
                                        child: TextButton.icon(
                                          onPressed: reviewControls,
                                          icon:
                                              const Icon(Icons.pending_actions),
                                          label: Text(
                                            c.currentRun!.snapshot
                                                    .pendingControls
                                                    .any(
                                              (p) => p['kind'] == 'approval',
                                            )
                                                ? 'Review action'
                                                : 'Answer needed',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Check status',
                                        onPressed: c.busy
                                            ? null
                                            : () => c.checkRunStatus(),
                                        icon: const Icon(Icons.refresh),
                                      ),
                                    ],
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: defaultTargetPlatform ==
                                                        TargetPlatform
                                                            .android &&
                                                    const {
                                                      'Sending your message',
                                                      'Waiting for its turn',
                                                      'Working on your reply',
                                                    }.contains(c.pendingStatus)
                                                ? const SizedBox.shrink()
                                                : Text(
                                                    c.pendingStatus,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                          ),
                                          if (c.currentRun!.runId == null)
                                            TextButton(
                                              onPressed: c.busy
                                                  ? null
                                                  : () => c.checkRunStatus(),
                                              child: const Text('Reconnect'),
                                            )
                                          else
                                            IconButton(
                                              tooltip: 'Check status',
                                              onPressed: c.busy
                                                  ? null
                                                  : () => c.checkRunStatus(),
                                              icon: const Icon(Icons.refresh),
                                            ),
                                        ],
                                      ),
                                      if (c.currentRun!.snapshot.status ==
                                              'unknown' &&
                                          c.currentRun!.runId != null)
                                        TextButton(
                                          onPressed: c.busy
                                              ? null
                                              : acknowledgeUnknown,
                                          child: const Text(
                                            'Acknowledge unknown outcome',
                                          ),
                                        ),
                                    ],
                                  ),
                          ),
                        SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // This strip consumes HTTP Runs activity, not
                                // canonical Gateway events. Android HTTP Runs
                                // only observes status. Keep controls below.
                                if (!c.usesRunStatusSync)
                                  AgentActivityStrip(
                                    model: activity.model,
                                    onOpenParent: openActivityParent,
                                    onOpenChildHistory: openActivityChild,
                                  ),
                                if (c.canonical != null)
                                  CanonicalComposerControls(
                                    chat: c.canonical!,
                                    composer: composer,
                                    queue: c.submit,
                                    onInterruptRequested: () => c.pauseQueue(
                                      'Stopped work pauses the queue. Review the result before choosing Resume.',
                                      session: session,
                                    ),
                                  ),
                                if (c.canGuideRun || c.canStopRun)
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      if (c.canGuideRun)
                                        IconButton(
                                          tooltip: 'Guide current work',
                                          onPressed: composer.text
                                                  .trim()
                                                  .isEmpty
                                              ? null
                                              : () async {
                                                  final text = composer.text;
                                                  if (await c.controlRun(
                                                        guidance: text,
                                                      ) &&
                                                      mounted &&
                                                      composer.text == text) {
                                                    if (_draftOwner != null) {
                                                      _drafts
                                                          .remove(_draftOwner);
                                                    }
                                                    composer.clear();
                                                    setState(() {});
                                                  }
                                                },
                                          icon: const Icon(
                                            Icons.assistant_direction_outlined,
                                          ),
                                        ),
                                      if (c.canStopRun)
                                        IconButton(
                                          tooltip: 'Stop current work',
                                          onPressed: () => c.controlRun(),
                                          icon: const Icon(
                                            Icons.stop_circle_outlined,
                                          ),
                                        ),
                                    ],
                                  ),
                                Container(
                                  padding:
                                      const EdgeInsets.fromLTRB(15, 4, 5, 4),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerLow,
                                    borderRadius: BorderRadius.circular(26),
                                    border: Border.all(
                                      color:
                                          Theme.of(context).colorScheme.outline,
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Expanded(
                                        child: GrowingMessageInput(
                                          controller: composer,
                                          enabled: session != null &&
                                              !c.unsavedChanges &&
                                              !c.organizationBlocked &&
                                              !c.readOnly &&
                                              !c.changingConnection,
                                          onChanged: (_) {
                                            _saveCurrentDraft();
                                            setState(() {});
                                          },
                                          onSubmit: c.readOnly ||
                                                  c.changingConnection ||
                                                  session == null ||
                                                  c.unsavedChanges ||
                                                  c.organizationBlocked ||
                                                  c.queueStatus != null
                                              ? null
                                              : send,
                                        ),
                                      ),
                                      PromptOptimizer(
                                        key: ValueKey(session?.id),
                                        controller: c,
                                        composer: composer,
                                        triggerBuilder: (context, openMenu) {
                                          final isDesktop = const {
                                            TargetPlatform.linux,
                                            TargetPlatform.macOS,
                                            TargetPlatform.windows,
                                          }.contains(
                                              Theme.of(context).platform);
                                          final sendTooltip = Tooltip(
                                            key: _sendTooltipKey,
                                            message: 'Send',
                                            triggerMode:
                                                TooltipTriggerMode.manual,
                                            child: IconButton.filled(
                                              onPressed: c.readOnly ||
                                                      c.changingConnection ||
                                                      session == null ||
                                                      c.unsavedChanges ||
                                                      c.organizationBlocked ||
                                                      c.queueStatus != null ||
                                                      composer.text
                                                          .trim()
                                                          .isEmpty
                                                  ? null
                                                  : send,
                                              icon: const Icon(
                                                Icons.arrow_upward_rounded,
                                              ),
                                            ),
                                          );
                                          return Focus(
                                            onKeyEvent: (node, event) {
                                              if (openMenu != null &&
                                                  event is KeyDownEvent &&
                                                  (event.logicalKey ==
                                                          LogicalKeyboardKey
                                                              .contextMenu ||
                                                      (event.logicalKey ==
                                                              LogicalKeyboardKey
                                                                  .f10 &&
                                                          HardwareKeyboard
                                                              .instance
                                                              .isShiftPressed))) {
                                                openMenu();
                                                return KeyEventResult.handled;
                                              }
                                              return KeyEventResult.ignored;
                                            },
                                            child: MergeSemantics(
                                              child: Semantics(
                                                onLongPress: openMenu,
                                                customSemanticsActions:
                                                    openMenu == null
                                                        ? null
                                                        : {
                                                            CustomSemanticsAction(
                                                              label:
                                                                  'Enhance prompt',
                                                            ): openMenu,
                                                          },
                                                child: GestureDetector(
                                                  excludeFromSemantics: true,
                                                  // Consume a hold even when optimization is disabled.
                                                  onLongPress: () =>
                                                      openMenu?.call(),
                                                  onSecondaryTap: openMenu,
                                                  child: isDesktop
                                                      ? MouseRegion(
                                                          onEnter: (_) =>
                                                              _sendTooltipKey
                                                                  .currentState
                                                                  ?.ensureTooltipVisible(),
                                                          onExit: (_) => Tooltip
                                                              .dismissAllToolTips(),
                                                          child: sendTooltip,
                                                        )
                                                      : sendTooltip,
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                                if (MediaQuery.viewInsetsOf(context).bottom ==
                                    0) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    'AI can make mistakes. Review important details.',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          );
        },
      );
}

class MessageView extends StatefulWidget {
  const MessageView({
    super.key,
    required this.text,
    required this.user,
    this.activityText,
    this.answerBuilder,
    this.usage,
    this.contextMetadata,
    this.pending = false,
    this.onCancelPending,
    this.onOpenLink,
  });
  final String text;
  final bool user;
  final bool pending;
  final VoidCallback? onCancelPending;

  /// Optional test/host hook for opening validated external Markdown links.
  final Future<bool> Function(Uri)? onOpenLink;
  final String? activityText;
  final Widget Function(Widget)? answerBuilder;
  final ReportedUsage? usage;
  final ConversationContextMetadata? contextMetadata;
  @override
  State<MessageView> createState() => _MessageViewState();
}

class _MessageViewState extends State<MessageView> {
  bool activity = false;
  bool _glow = false;
  Timer? _pulse;

  @override
  void dispose() {
    _pulse?.cancel();
    super.dispose();
  }

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
          const SnackBar(content: Text('Could not copy this message.')),
        );
      }
    }
  }

  Future<void> openLink(String? href) async {
    final uri = parseSafeMarkdownLink(href);
    if (uri == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(
                content: Text('Only web links (http/https) can be opened.')),
          );
      }
      return;
    }
    final opened = await openSafeMarkdownUri(uri, launch: widget.onOpenLink);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('Could not open this link.')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final animate = widget.pending &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context);
    if (animate) {
      _pulse ??= Timer.periodic(const Duration(seconds: 2), (_) {
        final lifecycle = WidgetsBinding.instance.lifecycleState;
        if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
          setState(() => _glow = !_glow);
        }
      });
    } else {
      _pulse?.cancel();
      _pulse = null;
      _glow = false;
    }
    final desktop = const {
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }.contains(Theme.of(context).platform);
    final markdown = widget.user
        ? null
        : MarkdownBody(
            data: widget.text,
            imageBuilder: safeMarkdownImageBuilder,
            selectable: false,
            onTapLink: (_, href, __) => unawaited(openLink(href)),
            styleSheet: saathiMarkdownStyle(context).copyWith(
              p: TextStyle(
                  fontSize: 18,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurface),
            ),
          );
    return Semantics(
      container: true,
      label: widget.pending
          ? 'Your pending message'
          : widget.user
              ? 'Your message'
              : 'Assistant message',
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Copy message'): copyMessage,
        if (!widget.user)
          CustomSemanticsAction(
                  label: activity ? 'Hide activity' : 'Show activity'):
              () => setState(() => activity = !activity),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: copyMessage,
        onHorizontalDragEnd:
            widget.user ? null : (_) => setState(() => activity = !activity),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 28),
          child: Align(
            alignment:
                widget.user ? Alignment.centerRight : Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (desktop && !widget.pending && widget.user)
                  IconButton(
                    tooltip: 'Copy message',
                    visualDensity: VisualDensity.compact,
                    onPressed: copyMessage,
                    icon: const Icon(Icons.copy_outlined, size: 16),
                  ),
                Flexible(
                  child: AnimatedContainer(
                    duration: animate
                        ? const Duration(milliseconds: 1400)
                        : Duration.zero,
                    curve: Curves.easeInOut,
                    constraints: const BoxConstraints(maxWidth: 720),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 14),
                    decoration: BoxDecoration(
                      color: widget.user
                          ? Theme.of(context).colorScheme.secondaryContainer
                          : Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: widget.pending
                          ? [
                              BoxShadow(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: _glow ? .22 : .08),
                                blurRadius: _glow ? 16 : 8,
                              )
                            ]
                          : null,
                    ),
                    child: Column(
                      crossAxisAlignment: widget.onCancelPending == null
                          ? CrossAxisAlignment.start
                          : CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.user)
                          Text(
                            widget.text,
                            style: TextStyle(
                                fontSize: 17,
                                height: 1.45,
                                fontStyle:
                                    widget.pending ? FontStyle.italic : null,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSecondaryContainer),
                          )
                        else ...[
                          if (widget.answerBuilder case final wrap?)
                            wrap(markdown!)
                          else
                            markdown!,
                          if (widget.usage case final usage?)
                            ReportedUsageLine(
                              usage: usage,
                              context: widget.contextMetadata,
                            ),
                        ],
                        if (widget.onCancelPending case final cancel?)
                          IconButton(
                            tooltip: 'Cancel pending message',
                            onPressed: cancel,
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        if (activity && !widget.user)
                          Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: Text(
                              widget.activityText ??
                                  'Activity · Response received\nOnly observable status is shown. No private reasoning.',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (desktop && !widget.pending && !widget.user) ...[
                  IconButton(
                    tooltip: 'Copy message',
                    visualDensity: VisualDensity.compact,
                    onPressed: copyMessage,
                    icon: const Icon(Icons.copy_outlined, size: 16),
                  ),
                  IconButton(
                    tooltip: activity ? 'Hide activity' : 'Show activity',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => activity = !activity),
                    icon: Icon(
                      activity ? Icons.info : Icons.info_outline,
                      size: 16,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
