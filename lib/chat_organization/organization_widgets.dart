import 'package:flutter/material.dart';
import 'organization.dart';
import 'persona_editor.dart';

enum ConversationWorkState {
  idle,
  queued,
  working,
  awaitingInput,
  failed,
  unknown,
  cancelled
}

extension ConversationWorkLabel on ConversationWorkState {
  String get label => switch (this) {
        ConversationWorkState.idle => '',
        ConversationWorkState.queued => 'Queued',
        ConversationWorkState.working => 'Working',
        ConversationWorkState.awaitingInput => 'Needs your input',
        ConversationWorkState.failed => 'Failed',
        ConversationWorkState.unknown => 'Outcome unknown',
        ConversationWorkState.cancelled => 'Cancelled'
      };
  IconData get icon => switch (this) {
        ConversationWorkState.idle => Icons.chat_bubble_outline,
        ConversationWorkState.queued => Icons.schedule,
        ConversationWorkState.working => Icons.more_horiz,
        ConversationWorkState.awaitingInput => Icons.front_hand_outlined,
        ConversationWorkState.failed => Icons.error_outline,
        ConversationWorkState.unknown => Icons.help_outline,
        ConversationWorkState.cancelled => Icons.cancel_outlined
      };
}

/// Subtle neutral gray background for read-only conversation rows, legible in
/// both light and dark themes.
Color readOnlyConversationTileColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF262626)
        : const Color(0xFFEEEEEE);

/// Supplied from the controller's original-conversation state, never a global
/// spinner. Neither working state nor inferred text creates an unread completion.
@immutable
class ConversationRowData {
  const ConversationRowData(
      {required this.identity,
      required this.title,
      this.subtitle = '',
      this.searchText = '',
      this.state = ConversationWorkState.idle,
      this.readOnly = false,
      this.latestMessageAt});
  final ConversationIdentity identity;
  final String title, subtitle, searchText;
  final ConversationWorkState state;
  final bool readOnly;
  final DateTime? latestMessageAt;
}

/// Compact, nonanimated and non-colour-only status, usable in row or app bar.
class ConversationStatus extends StatelessWidget {
  const ConversationStatus(
      {super.key,
      required this.state,
      required this.unread,
      this.readOnly = false});
  final ConversationWorkState state;
  final bool unread;
  final bool readOnly;
  @override
  Widget build(BuildContext context) => Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (readOnly)
              Text('Read-only', style: Theme.of(context).textTheme.labelSmall),
            if (state != ConversationWorkState.idle) ...[
              Icon(state.icon, size: 16, semanticLabel: state.label),
              Text(state.label, style: Theme.of(context).textTheme.labelSmall)
            ],
            if (unread)
              const Icon(Icons.mark_chat_unread_outlined,
                  size: 18, semanticLabel: 'Unread reply'),
          ]);
}

/// Contents for a native Scaffold Drawer (including real edge-swipe ownership).
/// Hosts can instead use ConversationActionRow inside their existing mixed list.
class ConversationOrganizationList extends StatefulWidget {
  const ConversationOrganizationList(
      {super.key,
      required this.organization,
      required this.rows,
      required this.onSelect,
      required this.onEdit,
      this.trailing = const []});
  final ChatOrganization organization;
  final List<ConversationRowData> rows;
  final ValueChanged<ConversationIdentity> onSelect;
  final Future<void> Function(ConversationIdentity) onEdit;
  final List<Widget> trailing;
  @override
  State<ConversationOrganizationList> createState() =>
      _ConversationOrganizationListState();
}

class _ConversationOrganizationListState
    extends State<ConversationOrganizationList> {
  String _query = '';
  bool _archived = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.organization,
      builder: (context, _) {
        final organization = widget.organization;
        final archived = widget.rows
            .where((r) => organization.entry(r.identity).archived)
            .toList();
        final attention = archived
            .where((r) =>
                organization.entry(r.identity).unread ||
                r.state != ConversationWorkState.idle)
            .length;
        final filtered = widget.rows.where((r) {
          final entry = organization.entry(r.identity);
          return entry.archived == _archived &&
              '${entry.title(r.title)} ${r.searchText}'
                  .toLowerCase()
                  .contains(_query.trim().toLowerCase());
        }).toList();
        final indexed = filtered.asMap().entries.toList();
        indexed.sort((a, b) {
          if (a.value.readOnly != b.value.readOnly) {
            return a.value.readOnly ? 1 : -1;
          }
          final aTime = a.value.latestMessageAt;
          final bTime = b.value.latestMessageAt;
          if (aTime != null && bTime != null) {
            final cmp = bTime.compareTo(aTime);
            if (cmp != 0) return cmp;
          } else if (aTime != null || bTime != null) {
            return aTime != null ? -1 : 1;
          }
          return a.key.compareTo(b.key);
        });
        final rows = [for (final entry in indexed) entry.value];
        return ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                      key: const ValueKey('conversation-search'),
                      decoration: const InputDecoration(
                          labelText: 'Search conversations',
                          prefixIcon: Icon(Icons.search)),
                      onChanged: (value) => setState(() => _query = value))),
              TextButton(
                  key: const ValueKey('archived-view'),
                  onPressed: () => setState(() => _archived = !_archived),
                  child: Text(_archived
                      ? 'Back to recent conversations'
                      : 'Archived (${archived.length}${attention > 0 ? ', $attention need attention' : ''})')),
              if (_archived)
                const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                        'Archived chats keep their history and any ongoing work. Search is limited to this view.')),
              if (organization.error != null)
                Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(organization.error!),
                          TextButton(
                              onPressed: organization.saving
                                  ? null
                                  : () async {
                                      try {
                                        await organization.retrySave();
                                      } catch (_) {}
                                    },
                              child: const Text('Try saving again'))
                        ])),
              for (final row in rows)
                ConversationActionRow(
                    key: ValueKey(row.identity.storageKey),
                    row: row,
                    presentation: organization.entry(row.identity),
                    onSelect: () => widget.onSelect(row.identity),
                    onEdit: () => widget.onEdit(row.identity),
                    onArchive: () async {
                      try {
                        await organization.setArchived(row.identity,
                            !organization.entry(row.identity).archived);
                      } catch (_) {}
                    }),
              ...widget.trailing,
            ]);
      });
}

/// Actions occupy a trailing rail underneath the translating row, never below it.
/// Horizontal gesture arena ownership leaves vertical list and edge drawer drags
/// to their normal owners. Menu offers the same actions without a swipe.
class ConversationActionRow extends StatefulWidget {
  const ConversationActionRow(
      {super.key,
      required this.row,
      required this.presentation,
      required this.onSelect,
      required this.onArchive,
      required this.onEdit,
      this.selected = false,
      bool? readOnly})
      : _readOnly = readOnly;
  final bool selected;
  final bool? _readOnly;
  bool get readOnly => _readOnly ?? row.readOnly;
  final ConversationRowData row;
  final ConversationPresentation presentation;
  final VoidCallback onSelect;
  final Future<void> Function() onArchive, onEdit;
  @override
  State<ConversationActionRow> createState() => _ConversationActionRowState();
}

class _ConversationActionRowState extends State<ConversationActionRow> {
  double _offset = 0;
  Future<void> _act(bool edit) async {
    setState(() => _offset = 0);
    if (edit) {
      await widget.onEdit();
    } else {
      await widget.onArchive();
    }
  }

  @override
  Widget build(BuildContext context) {
    final archived = widget.presentation.archived;
    return ClipRect(
        child: Stack(children: [
      if (_offset < 0)
        Positioned.fill(
            child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                    width: 176,
                    child: Row(children: [
                      Expanded(
                          child: Tooltip(
                              message: archived
                                  ? 'Restore conversation'
                                  : 'Archive conversation',
                              child: TextButton(
                                  style: TextButton.styleFrom(
                                      padding: EdgeInsets.zero),
                                  onPressed: () => _act(false),
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(archived
                                            ? Icons.unarchive_outlined
                                            : Icons.archive_outlined),
                                        Text(archived ? 'Restore' : 'Archive',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall)
                                      ])))),
                      Expanded(
                          child: Tooltip(
                              message: 'Edit conversation',
                              child: TextButton(
                                  style: TextButton.styleFrom(
                                      padding: EdgeInsets.zero),
                                  onPressed: () => _act(true),
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.edit_outlined),
                                        Text('Edit',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall)
                                      ])))),
                    ])))),
      GestureDetector(
          onHorizontalDragUpdate: (details) => setState(
              () => _offset = (_offset + details.delta.dx).clamp(-176, 0)),
          onHorizontalDragEnd: (_) =>
              setState(() => _offset = _offset < -40 ? -176 : 0),
          child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              transform: Matrix4.translationValues(_offset, 0, 0),
              child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: ListTile(
                    selected: widget.selected,
                    tileColor: widget.readOnly
                        ? readOnlyConversationTileColor(context)
                        : null,
                    selectedTileColor:
                        Theme.of(context).colorScheme.secondaryContainer,
                    onTap: widget.onSelect,
                    title: Text(widget.presentation.title(widget.row.title),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.row.subtitle.isNotEmpty)
                            Text(widget.row.subtitle,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                          ConversationStatus(
                              state: widget.row.state,
                              unread: widget.presentation.unread,
                              readOnly: widget.readOnly)
                        ]),
                    trailing: PopupMenuButton<bool>(
                        tooltip: 'Conversation actions',
                        onSelected: _act,
                        itemBuilder: (_) => [
                              PopupMenuItem(
                                  value: false,
                                  child:
                                      Text(archived ? 'Restore' : 'Archive')),
                              const PopupMenuItem(
                                  value: true, child: Text('Edit'))
                            ]),
                  )))),
    ]));
  }
}

/// Explicit Save/Cancel local edit. Dynamic restrictions are rechecked at Save.
Future<void> showConversationEdit(
        {required BuildContext context,
        required ChatOrganization organization,
        required ConversationIdentity identity,
        required String fallbackInstructions,
        required PersonaEditPolicy Function(ConversationIdentity) policy,
        required String? Function(ConversationIdentity) pendingReason}) =>
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ConversationEditDialog(
            organization: organization,
            identity: identity,
            fallbackInstructions: fallbackInstructions,
            policy: policy,
            pendingReason: pendingReason));
