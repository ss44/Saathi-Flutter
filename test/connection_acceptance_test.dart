import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/connections.dart';

const original = <String, dynamic>{
  'id': 'acceptance',
  'name': 'Original',
  'type': 'openai',
  'url': 'https://example.test',
};
const oldKey = 'acceptance-fixture-old-secret';
const newKey = 'acceptance-fixture-new-secret';

class AcceptanceSecrets extends MemorySecrets {
  bool failRead = false, failDelete = false;
  final writes = <String>[];
  @override
  Future<String?> read(String id) async {
    if (failRead) throw StateError('Synthetic read failure');
    return super.read(id);
  }

  @override
  Future<void> delete(String id) async {
    if (failDelete) throw StateError('Synthetic delete failure');
    await super.delete(id);
  }

  @override
  Future<void> write(String id, String value) async {
    writes.add(value);
    await super.write(id, value);
  }
}

class ThrowingPreferences extends InMemorySharedPreferencesStore {
  ThrowingPreferences() : super.empty();
  int attempts = 0;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    attempts++;
    throw StateError('Synthetic preference write/rollback failure');
  }
}

Future<ChatController> fixture(AcceptanceSecrets secrets) async {
  SharedPreferences.setMockInitialValues({});
  final c = ChatController(SaathiStore(
      preferences: await SharedPreferences.getInstance(), secrets: secrets));
  await c.load();
  await c.addConnection(original, oldKey);
  await c.newSession(original, 'fixture-model', 'fixture-prompt');
  c.current!.messages.add(ChatMessage(
      role: 'assistant',
      content: 'Existing local reply',
      metadata: {'apiKey': oldKey, 'token': newKey}));
  await c.persist();
  addTearDown(c.dispose);
  return c;
}

Future<void> noLeakedKeys(ChatController c) async {
  final prefs = c.store.preferences;
  final all =
      jsonEncode({for (final key in prefs.getKeys()) key: prefs.get(key)});
  final history = jsonEncode((await c.store.load()).chats);
  for (final key in [oldKey, newKey]) {
    expect(all, isNot(contains(key)));
    expect(history, isNot(contains(key)));
  }
}

Future<void> tapFormAction(WidgetTester t, String label) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await t.pumpAndSettle();
  final target = find.text(label);
  await t.scrollUntilVisible(target, 200,
      scrollable: find
          .descendant(
              of: find.byType(AddConnectionPage),
              matching: find.byType(Scrollable))
          .first);
  await t.ensureVisible(target);
  await t.pumpAndSettle();
  await t.tap(target);
  await t.pumpAndSettle();
}

Future<void> openEdit(WidgetTester t, ChatController c) async {
  await t.pumpWidget(MaterialApp(home: ConnectionsPage(controller: c)));
  await t.tap(find.byTooltip('Connection actions'));
  await t.pumpAndSettle();
  await t.tap(find.text('Edit'));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in ['unchanged', 'blank', 'rotation', 'clear', 'cancel']) {
    testWidgets('actual edit/save acceptance: $mode', (t) async {
      final secrets = AcceptanceSecrets();
      final c = await fixture(secrets);
      final historyBefore = jsonEncode((await c.store.load()).chats);
      await openEdit(t, c);
      await t.enterText(find.byType(TextFormField).at(0), 'Renamed');
      if (mode == 'blank' || mode == 'rotation' || mode == 'cancel') {
        await t.enterText(find.byKey(const Key('connection-key')),
            mode == 'blank' ? '' : newKey);
      }
      if (mode == 'clear') await tapFormAction(t, 'Clear stored key');
      if (mode == 'cancel') {
        await t.enterText(
            find.byType(TextFormField).at(1), 'https://other.test');
      }
      await tapFormAction(t, mode == 'cancel' ? 'Cancel' : 'Save connection');
      expect(find.byType(AddConnectionPage), findsNothing);
      expect(c.connections.single['id'], original['id']);
      expect(c.connections.single['name'],
          mode == 'cancel' ? 'Original' : 'Renamed');
      expect(c.connections.single['url'], original['url']);
      expect(
          await secrets.read('acceptance'),
          mode == 'clear'
              ? null
              : mode == 'rotation'
                  ? newKey
                  : oldKey);
      expect((await c.store.load()).connections.single, c.connections.single);
      expect(jsonEncode((await c.store.load()).chats), historyBefore);
      await noLeakedKeys(c);
      await t.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('secure-read failure disables Save and Show and preserves key',
      (t) async {
    final secrets = AcceptanceSecrets();
    final c = await fixture(secrets);
    secrets.failRead = true;
    await openEdit(t, c);
    expect(
        t
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.visibility))
            .onPressed,
        isNull);
    expect(
        t
            .widget<TextFormField>(find.byKey(const Key('connection-key')))
            .enabled,
        isFalse);
    await t.enterText(find.byType(TextFormField).at(0), 'Not saved');
    await t.scrollUntilVisible(find.text('Save connection'), 200,
        scrollable: find
            .descendant(
                of: find.byType(AddConnectionPage),
                matching: find.byType(Scrollable))
            .first);
    expect(find.textContaining('Secure key could not be read'), findsOneWidget);
    expect(
        t
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Save connection'))
            .onPressed,
        isNull);
    await tapFormAction(t, 'Cancel');
    secrets.failRead = false;
    expect(await secrets.read('acceptance'), oldKey);
    expect(c.connections.single, original);
    expect((await c.store.load()).connections.single, original);
    await noLeakedKeys(c);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('delete storage failure retains visible row and stored key',
      (t) async {
    final secrets = AcceptanceSecrets();
    final c = await fixture(secrets);
    secrets.failDelete = true;
    await t.pumpWidget(MaterialApp(home: ConnectionsPage(controller: c)));
    await t.tap(find.byTooltip('Connection actions'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    expect(find.text('Original'), findsOneWidget);
    expect(find.textContaining('Could not remove connection.'), findsOneWidget);
    expect(c.connections.single, original);
    expect((await c.store.load()).connections.single, original);
    expect(await secrets.read('acceptance'), oldKey);
    await noLeakedKeys(c);
    await t.pumpWidget(const SizedBox.shrink());
  });

  test(
      'provider change leaves current/history on old id read-only and blocks send',
      () async {
    final secrets = AcceptanceSecrets();
    final c = await fixture(secrets);
    final session = c.current!;
    final before = jsonEncode((await c.store.load()).chats);
    await c.updateConnection('acceptance', {...original, 'type': 'anthropic'});
    final newId = c.connections.single['id'] as String;
    expect(newId, isNot('acceptance'));
    expect(c.connections.single['type'], 'anthropic');
    expect(c.current, same(session));
    expect(c.current!.connectionId, 'acceptance');
    expect(c.readOnly, isTrue);
    expect(await c.send('must not be sent'), isFalse);
    expect(c.current!.messages.single.content, 'Existing local reply');
    expect(jsonEncode((await c.store.load()).chats), before);
    expect(await secrets.read('acceptance'), isNull);
    expect(await secrets.read(newId), oldKey);
    await noLeakedKeys(c);
  });

  test(
      'thrown preference rollback still restores secret and fails controller closed',
      () async {
    final secrets = AcceptanceSecrets();
    final c = await fixture(secrets);
    final previousPlatform = SharedPreferencesStorePlatform.instance;
    addTearDown(
        () => SharedPreferencesStorePlatform.instance = previousPlatform);
    final platform = ThrowingPreferences();
    SharedPreferencesStorePlatform.instance = platform;
    secrets.writes.clear();
    await expectLater(
        c.updateConnection('acceptance', {...original, 'name': 'Changed'},
            apiKey: newKey),
        throwsA(isA<StorageRecoveryException>()));
    expect(platform.attempts, 2);
    expect(secrets.writes, [newKey, oldKey]);
    expect(await secrets.read('acceptance'), oldKey);
    expect(c.connections.single, original);
    expect(c.readOnly, isTrue);
    expect(c.canChangeConnections, isFalse);
    expect(c.changingConnection, isFalse);
    expect(c.error, contains('recovery'));
    expect(await c.send('must not be sent'), isFalse);
    await expectLater(c.deleteConnection('acceptance'), throwsStateError);
    await expectLater(
        c.updateConnection('acceptance', original), throwsStateError);
    await expectLater(
        c.addConnection({...original, 'id': 'second'}, ''), throwsStateError);
    await noLeakedKeys(c);
  });
}
