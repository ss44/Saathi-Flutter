import 'package:flutter/material.dart';
import '../update_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'chat_controller.dart';
import 'connections.dart';
import 'safe_markdown.dart';

const muted = Color(0xFF6A7470);

class ChatHome extends StatefulWidget {
  const ChatHome({super.key, required this.controller});
  final ChatController controller;
  @override
  State<ChatHome> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<ChatHome> {
  final composer = TextEditingController();
  final scroll = ScrollController();
  ChatController get c => widget.controller;
  @override
  void dispose() {
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
    if (await c.send(text)) {
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
        final names = c.connections
            .where((entry) => entry['id'] == session?.connectionId);
        final subtitle = session == null
            ? 'Your models. Your space.'
            : '${names.isEmpty ? 'Unavailable connection' : names.first['name']} · ${session.model}';
        return Scaffold(
          appBar: AppBar(
              toolbarHeight: MediaQuery.textScalerOf(context).scale(32) + 24,
              titleSpacing: 0,
              title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Saathi',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700)),
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
                const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Conversations',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w600))),
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
                const SizedBox(height: 12),
                Expanded(
                    child: ListView(children: [
                  for (final s in c.sessions.reversed)
                    ListTile(
                        selected: s == session,
                        enabled: !c.busy,
                        title: Text(s.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('On this device · ${s.model}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          c.select(s);
                          composer.clear();
                          Navigator.pop(context);
                        })
                ])),
                const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('Local history stays bound to its connection.',
                        style: TextStyle(color: muted)))
              ]))),
          body: c.loading
              ? const Center(child: CircularProgressIndicator())
              : Column(children: [
                  const UpdateAvailabilityBanner(),
                  Expanded(
                      child: session == null ||
                              session.messages.isEmpty && !c.busy
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
                                  if (c.busy)
                                    const Padding(
                                        padding:
                                            EdgeInsets.symmetric(vertical: 18),
                                        child: Row(children: [
                                          SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2)),
                                          SizedBox(width: 12),
                                          Text('Waiting for response…',
                                              style: TextStyle(color: muted))
                                        ]))
                                ])),
                  if (c.error != null)
                    Container(
                        width: double.infinity,
                        color: Theme.of(context).colorScheme.errorContainer,
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
                  SafeArea(
                      top: false,
                      child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
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
                                              enabled:
                                                  session != null && !c.busy,
                                              minLines: 1,
                                              maxLines: 6,
                                              textCapitalization:
                                                  TextCapitalization.sentences,
                                              onChanged: (_) => setState(() {}),
                                              decoration: const InputDecoration(
                                                  hintText: 'Message Saathi',
                                                  border: InputBorder.none))),
                                      IconButton.filled(
                                          tooltip: 'Send',
                                          onPressed: session == null ||
                                                  c.busy ||
                                                  composer.text.trim().isEmpty
                                              ? null
                                              : send,
                                          icon: const Icon(
                                              Icons.arrow_upward_rounded))
                                    ])),
                            const SizedBox(height: 8),
                            const Text(
                                'AI can make mistakes. Review important details.',
                                style: TextStyle(fontSize: 11, color: muted))
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
