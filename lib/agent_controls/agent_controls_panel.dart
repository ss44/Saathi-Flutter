import 'package:flutter/material.dart';
import 'agent_controls.dart';

/// Only canonical pending controls are rendered, never model output or tool JSON.
/// No network, polling, or controller ownership. Parent refreshes on lifecycle
/// events and disposes the controller on source/run revision changes.
class AgentControlsPanel extends StatelessWidget {
  const AgentControlsPanel({super.key, required this.controller, this.redact});
  final AgentControlsController controller;
  final String Function(String)? redact;

  String _safe(String input) {
    String value;
    try {
      value = redact?.call(input) ?? input;
    } catch (_) {
      return '[Preview unavailable]';
    }
    if (value.length > 4000 || RegExp(r'^\s*[\[{]').hasMatch(value)) {
      return '[Preview unavailable]';
    }
    value = value.replaceAll(
        RegExp(
            r'-----BEGIN[\s\S]*?PRIVATE KEY-----[\s\S]*?-----END[\s\S]*?PRIVATE KEY-----'),
        '[redacted]');
    value = value.replaceAllMapped(
        RegExp(
            r'''\b(authorization\s*[:=]\s*(?:bearer\s+)?|bearer\s+|(?:api[_-]?key|token|password|secret|access[_-]?key)\s*[:=]\s*)["']?[^\s"',;]+''',
            caseSensitive: false),
        (m) => '${m[1]}[redacted]');
    value = value.replaceAll(
        RegExp(
            r'\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|AKIA[A-Z0-9]{16})\b'),
        '[redacted]');
    // Break unbroken tokens without shortening an approval preview.
    return value.replaceAllMapped(RegExp(r'\S{24,}'), (m) {
      final s = m[0]!;
      return [
        for (var i = 0; i < s.length; i += 24)
          s.substring(i, i + 24 < s.length ? i + 24 : s.length)
      ].join('\u200b');
    });
  }

  Widget _approval(PendingControl prompt) {
    final preview =
        prompt.canApprove ? _safe(prompt.command!) : '[Preview unavailable]';
    // Ignore non-rendering controls/formatting only for the visibility check;
    // preserve the displayed command and international text verbatim.
    final reviewable = preview
        .replaceAll(RegExp(r'[\p{Cf}\p{Cc}]', unicode: true), '')
        .replaceAll('[redacted]', '')
        .trim();
    final visible = reviewable.isNotEmpty && preview != '[Preview unavailable]';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(visible
          ? preview
          : 'Action preview unavailable. Approval is disabled.'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (prompt.choices.contains('once'))
          FilledButton(
            onPressed: visible && controller.canDecide(prompt, 'once')
                ? () => controller.decide(prompt, 'once')
                : null,
            child: const Text('Allow once'),
          ),
        if (prompt.choices.contains('deny'))
          OutlinedButton(
            onPressed: controller.canDecide(prompt, 'deny')
                ? () => controller.decide(prompt, 'deny')
                : null,
            child: const Text('Deny'),
          ),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          if (!controller.isCurrent) return const SizedBox.shrink();
          final snapshot = controller.snapshot;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
                12, 12, 12, 12 + MediaQuery.viewInsetsOf(context).bottom),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (controller.message != null)
                    Semantics(
                        liveRegion: true, child: Text(controller.message!)),
                  if (snapshot?.hasMalformedControls == true)
                    const Text('Some requests cannot be shown safely.'),
                  for (final prompt
                      in snapshot?.controls ?? <PendingControl>[]) ...[
                    const SizedBox(height: 12),
                    Card(
                        child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                      prompt.action == ControlAction.approval
                                          ? 'Review action'
                                          : 'Answer needed',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  if (prompt.description != null)
                                    Text(_safe(prompt.description!)),
                                  if (prompt.action == ControlAction.approval)
                                    _approval(prompt)
                                  else
                                    _Clarification(
                                      key: ValueKey(prompt.revision),
                                      controller: controller,
                                      prompt: prompt,
                                      safe: _safe,
                                    ),
                                  if (!controller.boundary
                                      .supportsAction(prompt.action))
                                    const Text(
                                        'Responding is not supported by this connection.'),
                                ]))),
                  ],
                  if (controller.busy)
                    const Padding(
                        padding: EdgeInsets.all(12),
                        child: LinearProgressIndicator()),
                  Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                          onPressed:
                              controller.busy ? null : controller.refresh,
                          child: const Text('Refresh'))),
                ]),
          );
        },
      );
}

class _Clarification extends StatefulWidget {
  const _Clarification(
      {super.key,
      required this.controller,
      required this.prompt,
      required this.safe});
  final AgentControlsController controller;
  final PendingControl prompt;
  final String Function(String) safe;
  @override
  State<_Clarification> createState() => _ClarificationState();
}

class _ClarificationState extends State<_Clarification> {
  final _answer = TextEditingController();
  String? _choice;
  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.prompt;
    final value = p.choices.isEmpty ? _answer.text : (_choice ?? '');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(widget.safe(p.question!)),
      if (p.choices.isEmpty)
        TextField(
            controller: _answer,
            enabled: !widget.controller.busy,
            minLines: 1,
            maxLines: 6,
            maxLength: 4000,
            decoration: const InputDecoration(labelText: 'Your answer'),
            onChanged: (_) => setState(() {}))
      else
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final choice in p.choices)
            ChoiceChip(
                label: Text(widget.safe(choice)),
                selected: _choice == choice,
                onSelected: widget.controller.busy
                    ? null
                    : (_) => setState(() => _choice = choice)),
        ]),
      Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
              onPressed: widget.controller.canDecide(p, value)
                  ? () => widget.controller.decide(p, value)
                  : null,
              child: const Text('Send'))),
    ]);
  }
}
