import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/transcript_presentation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../gateway/canonical_combined_controller_test.dart' as native;
import '../independent_feature_acceptance_review_test.dart' show TranscriptHost;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('canonical image-only terminal is retained without fetching its URL',
      () async {
    final (c, host, _) = await native.setup();
    expect(await c.send('first'), isTrue);
    host.history = [
      {
        'row_id': 3,
        'role': 'user',
        'content': 'first',
        'display_metadata': {'submission_id': host.inputId},
      },
      {
        'row_id': 4,
        'role': 'assistant',
        'content': [
          {
            'type': 'image_url',
            'image_url': {'url': 'https://untrusted.invalid/image'},
          },
        ],
      },
    ];
    host.terminal = true;
    await c.refreshCanonical();
    expect(c.runPending, isFalse);
    expect(c.error, isNull);
    final answer = c.current!.messages.last;
    expect(answer.content, contains('Image blocked'));
    expect(answer.id, 'canonical-chat-4');
    expect(showsHistoryBubble(answer), isTrue);
    final raw = c.store.preferences.getString('saathi.chats.v1')!;
    expect(raw, contains('Image blocked'));
    expect(raw, isNot(contains('untrusted.invalid')));
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
  });

  test('canonical paged transcript preserves image and tool identity on resync',
      () async {
    final host = TranscriptHost();
    await host.start();
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySecrets(),
    );
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
      'url': host.url,
    }, '');
    await c.connectCanonical(c.connections.single, host.invite);
    await c.attachCanonical(GatewaySession({'session_id': 'chat'}));
    host.rows.addAll([
      {
        'row_kind': 'message',
        'row_id': 3,
        'role': 'tool',
        'name': 'read_file',
        'text': 'PRIVATE TOOL BODY',
      },
      {
        'row_kind': 'message',
        'row_id': 4,
        'role': 'assistant',
        'content': [
          {
            'type': 'image',
            'source': {'url': 'file:///private/image'}
          },
          {'type': 'thinking', 'text': 'PRIVATE REASONING'},
        ],
      },
    ]);
    await c.refreshCanonical();
    final original = c.current!.messages.map((m) => m.toJson()).toList();
    expect(c.current!.messages.last.content, contains('Image blocked'));
    expect(c.current!.messages.last.id, 'canonical-chat-4');
    expect(c.current!.messages[2].metadata['canonicalRowKind'], 'toolActivity');
    expect(showsHistoryBubble(c.current!.messages[2]), isFalse);
    expect(precedingHistoryActivity(c.current!.messages, 3),
        'Tool activity: read_file');
    await c.refreshCanonical();
    expect(c.current!.messages.map((m) => m.toJson()).toList(), original);
    final raw = store.preferences.getString('saathi.chats.v1')!;
    expect(raw, isNot(contains('file:///')));
    expect(raw, isNot(contains('PRIVATE')));
    final restored = ChatController(store);
    await restored.load();
    expect(restored.sessions.single.messages.map((m) => m.toJson()).toList(),
        original);
    restored.dispose();
  });
}
