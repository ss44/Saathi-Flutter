import '../core/saathi_core.dart';

/// Project supported visible blocks before deciding whether a row is empty.
/// Images remain visible as blocked placeholders, never network/file requests.
/// Raw tool/reasoning blocks and hidden records never become answer text.
ChatMessage? projectRemoteHistory(Map<String, dynamic> row) {
  if (row['display_kind'] == 'hidden' ||
      !['user', 'assistant', 'model'].contains(row['role'])) {
    return null;
  }
  final content = row['content'];
  final text = content is String
      ? content
      : content is List
          ? [
              for (final block in content.whereType<Map>())
                if (block['type'] == 'text' && block['text'] is String)
                  block['text'] as String
                else if (['image', 'image_url'].contains(block['type']))
                  'Image blocked · attachment preview is unavailable',
            ].join('\n\n')
          : '';
  return ChatMessage(
      role: row['role'] == 'user' ? 'user' : 'model', content: text);
}

/// Presentation only: canonical rows and their indices remain untouched.
bool showsHistoryBubble(ChatMessage message) =>
    ['user', 'assistant', 'model'].contains(message.role) &&
    message.metadata['canonicalRowKind'] != 'toolActivity' &&
    message.content.trim().isNotEmpty;

/// Only the gateway's sanitized public tool labels belong in response activity.
/// Never expose raw tool bodies from imported local history.
String? precedingHistoryActivity(List<ChatMessage> messages, int index) {
  final labels = <String>[];
  for (var i = index - 1; i >= 0; i--) {
    final message = messages[i];
    if (showsHistoryBubble(message)) break;
    if (message.metadata['canonicalRowKind'] == 'toolActivity' &&
        message.content.trim().isNotEmpty) {
      labels.insert(0, message.content);
    }
  }
  return labels.isEmpty ? null : labels.join('\n');
}
