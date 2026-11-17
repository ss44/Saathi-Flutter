import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'independent_feature_acceptance_review_test.dart' show TranscriptHost;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
      'typed public rows persist separately while genuine answers still become unread',
      () async {
    final host = TranscriptHost();
    await host.start();
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    final c = ChatController(store);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    await c.load();
    await c.addConnection({
      'id': 'native',
      'name': 'Native',
      'type': 'hermesGateway',
      'url': host.url
    }, '');
    await c.connectCanonical(c.connections.single, host.invite);
    await c
        .attachCanonical(GatewaySession({'session_id': 'chat', 'title': 'A'}));
    final a = c.current!;
    final b = ChatSession(id: 'B', connectionId: 'native', model: 'other');
    c.sessions.add(b);
    c.select(b);
    host.rows.addAll([
      {
        'row_kind': 'message',
        'row_id': 3,
        'role': 'tool',
        'name': 'read_file',
        'text': 'PRIVATE_TOOL_BODY',
        'reasoning': 'PRIVATE_REASONING'
      },
      {'row_kind': 'compaction', 'row_id': 4, 'text': 'Public summary'},
      {'row_kind': 'message', 'row_id': 5, 'role': 'assistant', 'text': '  '},
      {
        'row_kind': 'message',
        'row_id': 6,
        'role': 'assistant',
        'display_kind': 'internal_notification',
        'text': 'Public activity'
      },
      {
        'row_kind': 'message',
        'row_id': 7,
        'role': 'assistant',
        'text': 'Tool activity: this is an actual answer'
      },
      {
        'row_kind': 'message',
        'row_id': 8,
        'role': 'assistant',
        'text': 'Conversation summary: this too is an answer'
      },
    ]);
    await c.refreshCanonical();
    final entry = c.organization.entry(c.identityOf(a));
    expect(entry.completions.keys, ['canonical-chat-7', 'canonical-chat-8']);
    expect(entry.unread, isTrue);
    final kinds = a.messages.skip(2).map((m) => m.metadata['canonicalRowKind']);
    expect(kinds, [
      'toolActivity',
      'compaction',
      'message',
      'publicNotice',
      'message',
      'message'
    ]);
    final raw = store.preferences.getString('saathi.chats.v1')!;
    expect(raw, isNot(contains('PRIVATE_TOOL_BODY')));
    expect(raw, isNot(contains('PRIVATE_REASONING')));
    final saved = (jsonDecode(raw) as List)
        .singleWhere((row) => row['id'] == a.id) as Map;
    expect(
        (saved['messages'] as List)
            .skip(2)
            .map((m) => m['metadata']['canonicalRowKind']),
        kinds);
    await c.refreshCanonical();
    expect(entry.completions.keys, ['canonical-chat-7', 'canonical-chat-8']);
  });
}
