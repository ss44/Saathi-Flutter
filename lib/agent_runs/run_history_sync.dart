import '../core/saathi_core.dart';
import '../ui/transcript_presentation.dart';

/// Outcome of matching a lost-receipt HTTP Runs submission against server
/// session history.
enum RunHistorySyncStatus {
  /// The submitted user message and its assistant reply were found after the
  /// existing local transcript prefix.
  matchedReply,

  /// The submitted user message was found after the existing local transcript
  /// prefix, but no visible assistant reply has been recorded yet.
  matchedUserPending,

  /// Server history aligned with local history, but the submitted user message
  /// has not appeared yet.
  notFound,

  /// Server history did not match the existing local transcript prefix; fail
  /// closed rather than attributing a foreign or rewritten transcript.
  diverged,
}

/// Typed result of reconciling an attempted, run-ID-less submission against
/// oldest-first rows returned by `GET /api/sessions/{session_id}/messages`.
class RunHistorySyncResult {
  const RunHistorySyncResult({
    required this.status,
    this.recoveredRunId,
    this.matchedUserMessageId,
    this.matchedReplyMessageId,
    this.replyText,
    this.replyTimestamp,
    this.precedingMessages = const [],
    this.trailingMessages = const [],
  });

  final RunHistorySyncStatus status;
  final String? recoveredRunId;
  final String? matchedUserMessageId;
  final String? matchedReplyMessageId;
  final String? replyText;
  final DateTime? replyTimestamp;
  final List<ChatMessage> precedingMessages;
  final List<ChatMessage> trailingMessages;
}

class _ProjectedHistoryRow {
  const _ProjectedHistoryRow({required this.message, required this.raw});
  final ChatMessage message;
  final Map<String, dynamic> raw;
}

final _validRunIdPattern = RegExp(r'^[a-zA-Z0-9_-]{1,256}$');

/// Normalizes line endings and outer whitespace for resilient text comparison
/// without altering stored message content.
String normalizeSyncMatchText(String text) =>
    text.replaceAll('\r\n', '\n').trim();

String? _extractValidRunId(Map<String, dynamic> raw) {
  for (final candidate in [
    raw['run_id'],
    if (raw['metadata'] is Map) (raw['metadata'] as Map)['run_id'],
    if (raw['display_metadata'] is Map)
      (raw['display_metadata'] as Map)['run_id'],
  ]) {
    if (candidate is String && _validRunIdPattern.hasMatch(candidate)) {
      return candidate;
    }
  }
  return null;
}

String? _extractServerMessageId(Map<String, dynamic> raw) {
  final id = raw['id'] ?? raw['message_id'];
  if (id is int) return '$id';
  if (id is String && id.isNotEmpty && id.length <= 256) return id;
  return null;
}

int? _findAlignedPrefixEnd(
  List<ChatMessage> existingMessages,
  List<_ProjectedHistoryRow> projected,
) {
  if (existingMessages.isEmpty) return 0;
  if (projected.length >= existingMessages.length) {
    var exact = true;
    for (var i = 0; i < existingMessages.length; i++) {
      if (projected[i].message.role != existingMessages[i].role ||
          normalizeSyncMatchText(projected[i].message.content) !=
              normalizeSyncMatchText(existingMessages[i].content)) {
        exact = false;
        break;
      }
    }
    if (exact) return existingMessages.length;
  }
  // Fall back to visible-bubble alignment when local history contains empty
  // rows omitted by server projection.
  final existingVisible = existingMessages.where(showsHistoryBubble).toList();
  if (existingVisible.isEmpty) return 0;
  var matched = 0;
  for (var i = 0; i < projected.length; i++) {
    final candidate = projected[i].message;
    if (!showsHistoryBubble(candidate)) continue;
    final expected = existingVisible[matched];
    if (candidate.role != expected.role ||
        normalizeSyncMatchText(candidate.content) !=
            normalizeSyncMatchText(expected.content)) {
      return null;
    }
    matched++;
    if (matched == existingVisible.length) return i + 1;
  }
  return null;
}

/// Matches [pendingInput] against oldest-first server history rows after
/// verifying prefix alignment with [existingMessages].
///
/// Only rows after the aligned local prefix are eligible, preventing an older
/// turn with identical text from falsely settling a newer submission.
RunHistorySyncResult matchAttemptedRunInHistory({
  required List<ChatMessage> existingMessages,
  required String pendingInput,
  required List<Map<String, dynamic>> rawRows,
}) {
  final target = normalizeSyncMatchText(pendingInput);
  if (target.isEmpty) {
    return const RunHistorySyncResult(status: RunHistorySyncStatus.notFound);
  }
  final projected = <_ProjectedHistoryRow>[];
  for (final row in rawRows) {
    final message = projectRemoteHistory(row);
    if (message != null) {
      projected.add(_ProjectedHistoryRow(message: message, raw: row));
    }
  }
  final prefixEnd = _findAlignedPrefixEnd(existingMessages, projected);
  if (prefixEnd == null) {
    return const RunHistorySyncResult(status: RunHistorySyncStatus.diverged);
  }
  final tail = projected.sublist(prefixEnd);
  var userOffset = -1;
  for (var i = 0; i < tail.length; i++) {
    if (tail[i].message.role == 'user' &&
        normalizeSyncMatchText(tail[i].message.content) == target) {
      userOffset = i;
      break;
    }
  }
  if (userOffset == -1) {
    return const RunHistorySyncResult(status: RunHistorySyncStatus.notFound);
  }

  final userRow = tail[userOffset];
  var recoveredRunId = _extractValidRunId(userRow.raw);
  final userMessageId = _extractServerMessageId(userRow.raw);

  int? replyOffset;
  for (var i = userOffset + 1; i < tail.length; i++) {
    final row = tail[i];
    if (row.message.role == 'user') break;
    recoveredRunId ??= _extractValidRunId(row.raw);
    if (row.message.role == 'model' && row.message.content.trim().isNotEmpty) {
      replyOffset = i;
      break;
    }
  }

  if (replyOffset == null) {
    return RunHistorySyncResult(
      status: RunHistorySyncStatus.matchedUserPending,
      recoveredRunId: recoveredRunId,
      matchedUserMessageId: userMessageId,
    );
  }

  final replyRow = tail[replyOffset];
  return RunHistorySyncResult(
    status: RunHistorySyncStatus.matchedReply,
    recoveredRunId: recoveredRunId,
    matchedUserMessageId: userMessageId,
    matchedReplyMessageId: _extractServerMessageId(replyRow.raw),
    replyText: replyRow.message.content,
    replyTimestamp: replyRow.message.timestamp,
    precedingMessages: [
      for (var i = 0; i < userOffset; i++) tail[i].message,
    ],
    trailingMessages: [
      for (var i = replyOffset + 1; i < tail.length; i++) tail[i].message,
    ],
  );
}
