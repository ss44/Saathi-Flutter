import 'package:flutter/material.dart';

import 'activity_model.dart';

/// Place directly above the composer in its resizing Scaffold. This module
/// neither opens connections nor invents child controls; callbacks are navigation
/// only. Child history must be read-only on the original bound connection.
class AgentActivityStrip extends StatelessWidget {
  const AgentActivityStrip(
      {super.key,
      required this.model,
      required this.onOpenParent,
      required this.onOpenChildHistory});
  final ActivityModel model;
  final void Function(ActivityBinding) onOpenParent;
  final void Function(ActivityBinding, ChildActivity) onOpenChildHistory;

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
        stream: model.changes,
        builder: (context, _) {
          final parents = model.visibleParents;
          if (!model.supported || (parents.isEmpty && !model.parentsOverflow)) {
            return const SizedBox.shrink();
          }
          final attention = parents.any((p) => p.status.needsAttention);
          return SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (context) => _ActivityPanel(
                        model: model,
                        onOpenParent: onOpenParent,
                        onOpenChildHistory: onOpenChildHistory)),
                icon: Icon(
                    attention
                        ? Icons.pending_actions
                        : Icons.account_tree_outlined,
                    size: 18),
                label: Text(
                    attention
                        ? 'Needs your attention'
                        : model.parentsOverflow
                            ? 'Agent activity · more tasks not shown'
                            : 'Agent activity',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ));
        },
      );
}

class _ActivityPanel extends StatelessWidget {
  const _ActivityPanel(
      {required this.model,
      required this.onOpenParent,
      required this.onOpenChildHistory});
  final ActivityModel model;
  final void Function(ActivityBinding) onOpenParent;
  final void Function(ActivityBinding, ChildActivity) onOpenChildHistory;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
        heightFactor: .8,
        child: StreamBuilder<void>(
            stream: model.changes,
            builder: (context, _) {
              final parents = model.visibleParents;
              return ListView(padding: const EdgeInsets.all(16), children: [
                Row(children: [
                  const Expanded(
                      child: Text('Agent activity',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold))),
                  IconButton(
                      tooltip: 'Close activity',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close))
                ]),
                if (model.parentsOverflow)
                  const Text(
                      'More active tasks not shown · retention limit reached'),
                if (parents.isEmpty) const Text('No active tasks'),
                for (final parent in parents) ...[
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                          parent.binding.connectionName.isEmpty
                              ? 'Original connection'
                              : parent.binding.connectionName,
                          style: Theme.of(context).textTheme.titleSmall)),
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(parent.binding.title.isEmpty
                          ? 'Conversation'
                          : parent.binding.title),
                      subtitle: Text(parent.status.label),
                      trailing: const Icon(Icons.chat_bubble_outline),
                      onTap: () {
                        if (!model.canNavigate(parent.binding)) return;
                        Navigator.pop(context);
                        onOpenParent(parent.binding);
                      }),
                  if (parent.batchTaskCount != null && parent.children.isEmpty)
                    const Text(
                        'Child tasks announced · details not yet available'),
                  if (parent.childrenOverflow)
                    const Text(
                        'More active child tasks not shown · retention limit reached'),
                  for (final child in parent.children)
                    ListTile(
                        contentPadding: const EdgeInsets.only(left: 12),
                        title: Text(child.goal,
                            maxLines: 3, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            [
                              child.status.label,
                              if (child.summary.isNotEmpty) child.summary,
                              child.childSessionId == null
                                  ? 'History unavailable'
                                  : 'Read-only history',
                            ].join(' · '),
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis),
                        trailing: child.childSessionId == null
                            ? null
                            : const Icon(Icons.history),
                        onTap: child.childSessionId == null
                            ? null
                            : () {
                                if (!model.canNavigate(parent.binding)) return;
                                Navigator.pop(context);
                                onOpenChildHistory(parent.binding, child);
                              }),
                ],
              ]);
            }),
      );
}
