import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/canonical_connection.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gateway/canonical_combined_controller_test.dart' show NativeHost;
import 'review38_independent_test.dart' show DelayedHistoryStore, until;

void main() {
  for (final boundary in [
    'Back',
    'cancel',
    'covered route',
    'covered roundtrip',
    'selection roundtrip'
  ]) {
    testWidgets(
        'late native persistence retains storage but loses navigation on $boundary',
        (t) async {
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      final host = NativeHost();
      final store = DelayedHistoryStore(
          preferences: await SharedPreferences.getInstance(),
          secrets: MemorySecrets());
      final c = ChatController(store);
      await t.runAsync(() async {
        await host.start();
        await c.load();
      });
      final nav = GlobalKey<NavigatorState>();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(MaterialApp(
          navigatorKey: nav,
          home: const Scaffold(body: Text('Home sentinel'))));
      final settings = MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Settings sentinel')));
      unawaited(nav.currentState!.push(settings));
      await t.pumpAndSettle();
      final attachRoute = MaterialPageRoute<void>(
          builder: (_) => CanonicalConnectionPage(controller: c));
      unawaited(nav.currentState!.push(attachRoute));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('gateway-trusted-url')), host.url);
      await t.enterText(
          find.widgetWithText(TextField, 'Host-issued invite JSON'),
          host.invite);
      final scroll = find
          .descendant(
              of: find.byType(ListView), matching: find.byType(Scrollable))
          .first;
      await t.scrollUntilVisible(find.text('Trust this host and connect'), 150,
          scrollable: scroll);
      await t.tap(find.text('Trust this host and connect'));
      await until(
          t,
          () =>
              host.requests
                      .where((r) => r['method'] == 'session.list')
                      .length ==
                  2 &&
              find.text('Trust this host and connect').evaluate().isNotEmpty,
          'connected list');
      await t.scrollUntilVisible(find.text('Native A'), 150,
          scrollable: scroll);
      await t.pumpAndSettle();
      store.gate = Completer<void>();
      await t.tap(find.text('Native A'));
      await until(t, () => store.started, 'history write accepted');
      final original = c.current!;
      final owner = c.canonical!;
      expect(original.remoteSessionId, 'chat');
      expect(original.canonicalProfileId, 'profile');
      expect(original.messages.map((m) => m.content),
          ['Earlier input', 'Earlier reply']);
      if (boundary == 'Back') {
        await t.tap(find.byTooltip('Back'));
        await t.pump(const Duration(milliseconds: 1));
      } else if (boundary == 'cancel') {
        nav.currentState!.pop();
        await t.pump(const Duration(milliseconds: 1));
      } else if (boundary.startsWith('covered')) {
        unawaited(nav.currentState!.push(MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Cover sentinel')))));
        await t.pumpAndSettle();
        if (boundary == 'covered roundtrip') {
          nav.currentState!.pop();
          await t.pumpAndSettle();
        }
      } else {
        final other = ChatSession(
            id: 'other', connectionId: original.connectionId, model: 'other');
        c.sessions.add(other);
        c.select(other);
        c.select(original);
      }
      expect(find.byType(CanonicalConnectionPage, skipOffstage: false),
          findsOneWidget);
      store.gate!.complete();
      await until(
          t,
          () =>
              !owner.connected &&
              store.preferences.getString('saathi.chats.v1') != null,
          'saved and revoked');
      // Drain the real WebSocket closing handshake as well as widget frames.
      for (var i = 0; i < 10; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump(const Duration(milliseconds: 10));
      }
      await t.pumpAndSettle();
      expect(settings.isActive, isTrue);
      expect(settings.isCurrent, boundary == 'Back' || boundary == 'cancel');
      expect(attachRoute.isCurrent,
          boundary == 'covered roundtrip' || boundary == 'selection roundtrip');
      if (boundary == 'covered route') {
        expect(find.text('Cover sentinel'), findsOneWidget);
      }
      expect(c.current, same(original));
      expect(c.readOnly, isTrue);
      expect(c.unsavedChanges, isFalse);
      final saved =
          jsonDecode(store.preferences.getString('saathi.chats.v1')!) as List;
      expect(saved.single['id'], original.id);
      expect(saved.single['remoteSessionId'], 'chat');
      expect(saved.single['messages'], hasLength(2));
      expect(
          host.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await t.runAsync(host.close);
      await t.pump(const Duration(seconds: 6));
    });
  }
}
