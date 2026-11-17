import 'package:flutter/material.dart';
import '../gateway/canonical_chat.dart';
import '../gateway/hermes_gateway.dart';

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
        builder: (context, _) =>
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (chat.snapshot?.requests.isNotEmpty ?? false)
            Expanded(
                child: TextButton.icon(
              onPressed: chat.connected && !chat.controlBusy
                  ? () => showDialog<void>(
                      context: context,
                      builder: (_) => _NativeDecision(
                          chat: chat, prompt: chat.snapshot!.requests.first))
                  : null,
              icon: const Icon(Icons.pending_actions),
              label: Text(
                  chat.snapshot!.requests.first.kind == 'approval'
                      ? 'Review action'
                      : 'Answer needed',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            )),
          PopupMenuButton<String>(
            tooltip: 'Use draft while Hermes works',
            enabled: chat.canControl && composer.text.trim().isNotEmpty,
            onSelected: (action) async {
              final text = composer.text;
              final revision = composer.value;
              final accepted = await chat.control(
                  action == 'interruptQueue' ? 'interrupt' : action,
                  text: text);
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
              PopupMenuItem(value: 'steer', child: Text('Guide current work')),
              PopupMenuItem(
                  value: 'redirect', child: Text('Correct current work')),
              PopupMenuItem(
                  value: 'interruptQueue',
                  child: Text('Interrupt, then queue draft')),
            ],
            icon: const Icon(Icons.assistant_direction_outlined),
          ),
          IconButton(
              tooltip: 'Stop current Hermes work',
              onPressed: chat.canControl
                  ? () {
                      onInterruptRequested?.call();
                      chat.control('interrupt');
                    }
                  : null,
              icon: const Icon(Icons.stop_circle_outlined)),
        ]),
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.chat,
      builder: (context, _) {
        final prompt = widget.prompt;
        final enabled = !submitting &&
            widget.chat.connected &&
            (widget.chat.snapshot?.requests.contains(prompt) ?? false);
        return AlertDialog(
          title: Text(
              prompt.kind == 'approval' ? 'Review action' : 'Answer needed'),
          scrollable: true,
          content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (prompt.kind == 'approval' &&
                    prompt.approvalPreview != null &&
                    prompt.descriptionPreview != null)
                  Text(prompt.descriptionPreview!),
                Text(prompt.kind == 'approval'
                    ? prompt.approvalPreview ??
                        'Action preview unavailable. Approval is disabled.'
                    : prompt.question),
                if (!enabled && !submitting)
                  const Text(
                      'This request changed. Close and resync the session.'),
                if (prompt.kind == 'approval')
                  for (final choice in prompt.choices)
                    TextButton(
                        onPressed: enabled &&
                                (choice == 'deny' ||
                                    prompt.approvalPreview != null)
                            ? () => decide(choice)
                            : null,
                        child: Text(choice))
                else ...[
                  for (final choice in prompt.choices)
                    TextButton(
                        onPressed: enabled
                            ? () {
                                answer.text = choice;
                              }
                            : null,
                        child: Text(choice)),
                  TextField(
                      controller: answer,
                      enabled: enabled,
                      minLines: 1,
                      maxLines: 4,
                      decoration:
                          const InputDecoration(labelText: 'Your answer')),
                ],
              ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close')),
            if (prompt.kind == 'clarify')
              TextButton(
                  onPressed: enabled ? () => decide(answer.text) : null,
                  child: const Text('Answer')),
          ],
        );
      });
}
