import 'package:flutter/material.dart';
import '../gateway/canonical_chat.dart';
import '../gateway/hermes_gateway.dart';

/// Maps a backend-advertised Gateway approval choice token to a human-readable
/// label without inventing choices the server did not advertise.
String approvalChoiceLabel(String choice) => switch (choice) {
      'once' || 'allow_once' => 'Allow once',
      'always' || 'allow_always' => 'Always allow',
      'deny' => 'Deny',
      _ => choice,
    };

/// Native busy controls are separate from the composer's ordinary FIFO Send.
class CanonicalComposerControls extends StatelessWidget {
  const CanonicalComposerControls(
      {super.key,
      required this.chat,
      required this.composer,
      required this.queue,
      this.onInterruptRequested});
  final CanonicalChat chat;
  final TextEditingController composer;
  final bool Function(String) queue;

  /// Pause the original conversation's followers before an ordinary Stop.
  /// The explicit interrupt-then-queue action retains its separate semantics.
  final VoidCallback? onInterruptRequested;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([chat, composer]),
        builder: (context, _) {
          final colors = Theme.of(context).colorScheme;
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (chat.snapshot?.requests.isNotEmpty ?? false) ...[
                  Expanded(
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: chat.connected && !chat.controlBusy
                          ? () => showDialog<void>(
                                context: context,
                                builder: (_) => _NativeDecision(
                                  chat: chat,
                                  prompt: chat.snapshot!.requests.first,
                                ),
                              )
                          : null,
                      icon: const Icon(Icons.pending_actions, size: 18),
                      label: Text(
                        chat.snapshot!.requests.first.kind == 'approval'
                            ? 'Review action'
                            : 'Answer needed',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                PopupMenuButton<String>(
                  tooltip: 'Use draft while Hermes works',
                  enabled: chat.canControl && composer.text.trim().isNotEmpty,
                  onSelected: (action) async {
                    final text = composer.text;
                    final revision = composer.value;
                    final accepted = await chat.control(
                      action == 'interruptQueue' ? 'interrupt' : action,
                      text: text,
                    );
                    if (!context.mounted ||
                        !accepted ||
                        !chat.connected ||
                        composer.value != revision) {
                      return;
                    }
                    if (action == 'interruptQueue' && !queue(text)) return;
                    composer.clear();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'steer',
                      child: Text('Guide current work'),
                    ),
                    PopupMenuItem(
                      value: 'redirect',
                      child: Text('Correct current work'),
                    ),
                    PopupMenuItem(
                      value: 'interruptQueue',
                      child: Text('Interrupt, then queue draft'),
                    ),
                  ],
                  icon: const Icon(Icons.assistant_direction_outlined),
                ),
                Tooltip(
                  message: 'Stop current Hermes work',
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.error,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onPressed: chat.canControl
                        ? () {
                            onInterruptRequested?.call();
                            chat.control('interrupt');
                          }
                        : null,
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('Stop'),
                  ),
                ),
              ],
            ),
          );
        },
      );
}

class _NativeDecision extends StatefulWidget {
  const _NativeDecision({required this.chat, required this.prompt});
  final CanonicalChat chat;
  final GatewayRequest prompt;
  @override
  State<_NativeDecision> createState() => _NativeDecisionState();
}

class _NativeDecisionState extends State<_NativeDecision> {
  final answer = TextEditingController();
  bool submitting = false;
  @override
  void dispose() {
    answer.dispose();
    super.dispose();
  }

  Future<void> decide(String value) async {
    if (submitting) return;
    setState(() => submitting = true);
    final accepted = await widget.chat.decide(widget.prompt, value);
    if (!mounted) return;
    if (accepted) {
      Navigator.of(context).pop();
    } else {
      setState(() => submitting = false);
    }
  }

  Widget _approvalChoiceButton(
    BuildContext context,
    String choice, {
    required bool enabled,
    required bool reviewable,
  }) {
    final colors = Theme.of(context).colorScheme;
    final onPressed = enabled && (choice == 'deny' || reviewable)
        ? () => decide(choice)
        : null;
    final label = Text(approvalChoiceLabel(choice));
    if (choice == 'once' || choice == 'allow_once') {
      return FilledButton(onPressed: onPressed, child: label);
    }
    if (choice == 'deny') {
      return OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.error,
          side: onPressed == null ? null : BorderSide(color: colors.error),
        ),
        onPressed: onPressed,
        child: label,
      );
    }
    return OutlinedButton(onPressed: onPressed, child: label);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.chat,
        builder: (context, _) {
          final colors = Theme.of(context).colorScheme;
          final prompt = widget.prompt;
          final enabled = !submitting &&
              widget.chat.connected &&
              (widget.chat.snapshot?.requests.contains(prompt) ?? false);
          final reviewable = prompt.approvalPreview != null;
          return AlertDialog(
            title: Text(
              prompt.kind == 'approval' ? 'Review action' : 'Answer needed',
            ),
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (prompt.kind == 'approval') ...[
                  if (reviewable && prompt.descriptionPreview != null) ...[
                    Text(prompt.descriptionPreview!),
                    const SizedBox(height: 10),
                  ],
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: reviewable
                          ? colors.surfaceContainerHighest
                          : colors.errorContainer,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Text(
                      prompt.approvalPreview ??
                          'Action preview unavailable. Approval is disabled.',
                      style: TextStyle(
                        fontFamily: reviewable ? 'monospace' : null,
                        color: reviewable
                            ? colors.onSurface
                            : colors.onErrorContainer,
                      ),
                    ),
                  ),
                ] else
                  Text(prompt.question),
                if (!enabled && !submitting) ...[
                  const SizedBox(height: 8),
                  Text(
                    'This request changed. Close and resync the session.',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
                if (prompt.kind == 'approval') ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final choice in prompt.choices)
                        _approvalChoiceButton(
                          context,
                          choice,
                          enabled: enabled,
                          reviewable: reviewable,
                        ),
                    ],
                  ),
                ] else ...[
                  if (prompt.choices.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final choice in prompt.choices)
                          OutlinedButton(
                            onPressed: enabled
                                ? () {
                                    answer.text = choice;
                                  }
                                : null,
                            child: Text(choice),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextField(
                    controller: answer,
                    enabled: enabled,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: 'Your answer'),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
              if (prompt.kind == 'clarify')
                FilledButton(
                  onPressed: enabled ? () => decide(answer.text) : null,
                  child: const Text('Answer'),
                ),
            ],
          );
        },
      );
}
