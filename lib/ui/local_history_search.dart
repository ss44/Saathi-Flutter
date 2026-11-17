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
    Iterable<ChatSession> sessions, String query,
    {String Function(ChatSession)? displayTitle}) {
  final needle = query.trim().toLowerCase();
  return [
    for (final session in sessions)
      if (needle.isEmpty)
        LocalHistoryMatch(session, null)
      else if (_matchingText(session, needle, displayTitle?.call(session))
          case final String text)
        LocalHistoryMatch(session, _snippet(text, needle))
  ];
}

String? _matchingText(
    ChatSession session, String needle, String? displayTitle) {
  for (final message in session.messages) {
    if (message.content.toLowerCase().contains(needle)) return message.content;
  }
  final title = displayTitle ?? session.title;
  return title.toLowerCase().contains(needle) ? title : null;
}

String _snippet(String text, String needle) {
  final index = text.toLowerCase().indexOf(needle);
  final start = math.max(0, index - 36);
  final end = math.min(text.length, start + 140);
  return '${start > 0 ? '…' : ''}${text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ')}${end < text.length ? '…' : ''}';
}
