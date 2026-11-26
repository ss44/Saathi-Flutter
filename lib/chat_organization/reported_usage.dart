import 'package:flutter/material.dart';

/// Strict projection of the core's normalized usage. Never persists raw provider
/// metadata, fills missing counters with zero, or treats tokens as money/context.
@immutable
class ReportedUsage {
  const ReportedUsage({this.input, this.output, this.total});
  final int? input, output, total;
  static int? _count(Object? value) =>
      value is int && value >= 0 && value <= 1000000000 ? value : null;
  factory ReportedUsage.fromMetadata(Map<String, dynamic> metadata) =>
      ReportedUsage(
          input: _count(metadata['promptTokens']),
          output: _count(metadata['completionTokens']),
          total: _count(metadata['totalTokens']));
  bool get available => input != null || output != null || total != null;
  Map<String, int> toMetadata() => {
        if (input != null) 'promptTokens': input!,
        if (output != null) 'completionTokens': output!,
        if (total != null) 'totalTokens': total!
      };
}

/// Context ownership and retained local display rows are distinct from measured
/// model tokens. Supply modelLimit only from a verified model contract, not a
/// name-prefix table, local transcript length or heuristic tokenizer.
@immutable
class ConversationContextMetadata {
  const ConversationContextMetadata(
      {required this.serverOwned, this.retainedMessages, this.modelLimit});
  final bool serverOwned;
  final int? retainedMessages, modelLimit;
}

/// Small answer-level usage disclosure. No estimates, progress bar or prices.
class ReportedUsageLine extends StatelessWidget {
  const ReportedUsageLine({super.key, required this.usage, this.context});
  final ReportedUsage usage;
  final ConversationContextMetadata? context;
  @override
  Widget build(BuildContext context) {
    if (!usage.available) return const SizedBox.shrink();
    final summary = usage.total != null
        ? '${usage.total} total'
        : usage.input != null
            ? 'Input ${usage.input}'
            : 'Output ${usage.output}';
    final info = this.context;
    return Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            dense: true,
            title: Text('Reported tokens · $summary',
                style: Theme.of(context).textTheme.labelSmall),
            children: [
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      [
                        'Input ${usage.input ?? 'unavailable'} · Output ${usage.output ?? 'unavailable'} · Total ${usage.total ?? 'unavailable'}',
                        if (info?.serverOwned == true)
                          'Server-owned context; local history does not measure the server’s active model context.'
                        else
                          'Local history is display/context retained by this app, not an exact active model token count.',
                        if (info?.retainedMessages case final int count
                            when count >= 0)
                          '$count locally retained messages.',
                        if (info?.modelLimit case final int limit
                            when limit > 0 && limit <= 1000000000)
                          'Reported model context limit: $limit tokens.'
                        else
                          'The model context limit is unavailable.',
                      ].join('\n'),
                      style: Theme.of(context).textTheme.bodySmall))
            ]));
  }
}
