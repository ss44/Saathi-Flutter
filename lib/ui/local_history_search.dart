import 'dart:math' as math;
import 'chat_controller.dart';

class LocalHistoryMatch {
  const LocalHistoryMatch(this.session, this.snippet);
  final ChatSession session;
  final String? snippet;
}

/// Display content only: no connection secrets, prompts or provider metadata.
/// Input order is retained; callers supply newest-first local conversations.
List<LocalHistoryMatch> searchLocalHistory(
    Iterable<ChatSession> sessions, String query) {
  final needle = query.trim().toLowerCase();
  return [
    for (final session in sessions)
      if (needle.isEmpty)
        LocalHistoryMatch(session, null)
      else if (_matchingText(session, needle) case final String text)
        LocalHistoryMatch(session, _snippet(text, needle))
  ];
}

String? _matchingText(ChatSession session, String needle) {
  for (final message in session.messages) {
    if (message.content.toLowerCase().contains(needle)) return message.content;
  }
  return session.title.toLowerCase().contains(needle) ? session.title : null;
}

String _snippet(String text, String needle) {
  final index = text.toLowerCase().indexOf(needle);
  final start = math.max(0, index - 36);
  final end = math.min(text.length, start + 140);
  return '${start > 0 ? '…' : ''}${text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ')}${end < text.length ? '…' : ''}';
}
