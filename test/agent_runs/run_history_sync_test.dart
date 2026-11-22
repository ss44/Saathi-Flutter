import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/agent_runs/run_history_sync.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';

void main() {
  group('matchAttemptedRunInHistory', () {
    test('aligns visible prefix when local history contains empty rows', () {
      final result = matchAttemptedRunInHistory(
        existingMessages: [
          ChatMessage(role: 'user', content: 'first'),
          ChatMessage(role: 'model', content: '   '),
          ChatMessage(role: 'model', content: 'first reply'),
        ],
        pendingInput: 'second\r\nline',
        rawRows: [
          {'id': 1, 'role': 'user', 'content': 'first'},
          {'id': 2, 'role': 'assistant', 'content': 'first reply'},
          {
            'id': 3,
            'role': 'assistant',
            'content': 'hidden',
            'display_kind': 'hidden'
          },
          {'id': 4, 'role': 'user', 'content': '  second\nline  '},
          {'id': 5, 'role': 'assistant', 'content': 'second reply'},
        ],
      );
      expect(result.status, RunHistorySyncStatus.matchedReply);
      expect(result.matchedUserMessageId, '4');
      expect(result.matchedReplyMessageId, '5');
      expect(result.replyText, 'second reply');
    });

    test('captures preceding and trailing synced messages and metadata run_id',
        () {
      final result = matchAttemptedRunInHistory(
        existingMessages: [
          ChatMessage(role: 'user', content: 'old'),
          ChatMessage(role: 'model', content: 'old reply'),
        ],
        pendingInput: 'my turn',
        rawRows: [
          {'id': 1, 'role': 'user', 'content': 'old'},
          {'id': 2, 'role': 'assistant', 'content': 'old reply'},
          {'id': 3, 'role': 'user', 'content': 'other device prompt'},
          {'id': 4, 'role': 'assistant', 'content': 'other device reply'},
          {
            'message_id': 'u-5',
            'role': 'user',
            'content': 'my turn',
            'display_metadata': {'run_id': 'run_meta_7'},
          },
          {
            'message_id': 'a-6',
            'role': 'assistant',
            'content': 'my reply',
            'timestamp': '2026-11-22T18:30:00Z',
          },
          {'id': 7, 'role': 'user', 'content': 'later turn'},
          {'id': 8, 'role': 'assistant', 'content': 'later reply'},
        ],
      );
      expect(result.status, RunHistorySyncStatus.matchedReply);
      expect(result.recoveredRunId, 'run_meta_7');
      expect(result.matchedUserMessageId, 'u-5');
      expect(result.matchedReplyMessageId, 'a-6');
      expect(result.replyText, 'my reply');
      expect(result.replyTimestamp, DateTime.utc(2026, 11, 22, 18, 30));
      expect(result.precedingMessages.map((m) => m.content),
          ['other device prompt', 'other device reply']);
      expect(result.trailingMessages.map((m) => m.content),
          ['later turn', 'later reply']);
    });

    test('rejects invalid run_id values and handles pending user turn', () {
      final result = matchAttemptedRunInHistory(
        existingMessages: const [],
        pendingInput: 'still running',
        rawRows: [
          {
            'id': 1,
            'role': 'user',
            'content': 'still running',
            'run_id': '../bad/run',
            'metadata': {'run_id': 'valid_run_9'},
          },
        ],
      );
      expect(result.status, RunHistorySyncStatus.matchedUserPending);
      expect(result.recoveredRunId, 'valid_run_9');
      expect(result.matchedUserMessageId, '1');
    });

    test('returns notFound for blank input or missing user turn', () {
      expect(
        matchAttemptedRunInHistory(
          existingMessages: const [],
          pendingInput: '   ',
          rawRows: const [],
        ).status,
        RunHistorySyncStatus.notFound,
      );
      expect(
        matchAttemptedRunInHistory(
          existingMessages: const [],
          pendingInput: 'missing',
          rawRows: [
            {'id': 1, 'role': 'user', 'content': 'different'},
          ],
        ).status,
        RunHistorySyncStatus.notFound,
      );
    });

    test('returns diverged when existing prefix does not match remote rows',
        () {
      final result = matchAttemptedRunInHistory(
        existingMessages: [
          ChatMessage(role: 'user', content: 'local A'),
          ChatMessage(role: 'model', content: 'local B'),
        ],
        pendingInput: 'new',
        rawRows: [
          {'id': 1, 'role': 'user', 'content': 'remote X'},
          {'id': 2, 'role': 'user', 'content': 'new'},
          {'id': 3, 'role': 'assistant', 'content': 'reply'},
        ],
      );
      expect(result.status, RunHistorySyncStatus.diverged);
    });
  });

  group('RunClient.sessionMessages', () {
    test('validates bounds, authority, session id, and response schema',
        () async {
      late http.Response nextResponse;
      final client = RunClient(
        'https://hermes.example',
        'secret',
        client: MockClient((_) async => nextResponse),
      );
      addTearDown(client.close);
      final op = await client.prepare(
        RunLedger(MemorySecrets()),
        local: 'chat1',
        existingSessionId: 'sess_ok',
        input: 'hi',
        model: 'm',
        instructions: '',
        history: const [],
      );

      await expectLater(
        client.sessionMessages(op, limit: 0),
        throwsArgumentError,
      );
      await expectLater(
        client.sessionMessages(op, isCurrent: () => false),
        throwsStateError,
      );

      nextResponse = http.Response('{}', 503);
      await expectLater(client.sessionMessages(op), throwsStateError);

      nextResponse = http.Response(
        jsonEncode({'session_id': 'wrong', 'data': []}),
        200,
      );
      await expectLater(client.sessionMessages(op), throwsStateError);

      nextResponse = http.Response(
        jsonEncode({'session_id': 'sess_ok', 'data': 'not-a-list'}),
        200,
      );
      await expectLater(client.sessionMessages(op), throwsFormatException);

      nextResponse = http.Response(
        jsonEncode({
          'session_id': 'sess_ok',
          'data': [],
          'pagination': {'offset': 5, 'limit': 100, 'returned': 0},
        }),
        200,
      );
      await expectLater(client.sessionMessages(op), throwsFormatException);

      nextResponse = http.Response(
        jsonEncode({
          'session_id': 'sess_ok',
          'data': [
            {'id': 1, 'role': 'user', 'content': 'hi'}
          ],
          'pagination': {'offset': 0, 'limit': 100, 'returned': 1},
        }),
        200,
      );
      final page = await client.sessionMessages(op);
      expect(page.sessionId, 'sess_ok');
      expect(page.messages, hasLength(1));
    });
  });
}
