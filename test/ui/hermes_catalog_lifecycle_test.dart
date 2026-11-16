import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/connections.dart';
import 'controller_http_test.dart' show makeStore;
import 'hermes_catalog_security_test.dart' show DelayedSecrets;

const catalogCapabilities =
    '{"features":{"model_options":true},"endpoints":{"model_options":{"method":"GET","path":"/api/model/options"}}}';
const enrichedCatalog =
    '{"current_provider":"two","current_model":"same","providers":[{"slug":"one","name":"One","authenticated":true,"api_url":"https://never-contact.invalid","models":["same","same"]},{"slug":"two","name":"Two","authenticated":true,"models":["same"]},{"slug":"unconfigured","authenticated":false,"models":["hidden"]}]}';

Future<void> mountPicker(WidgetTester tester, ChatController controller) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(MaterialApp(home: ChatHome(controller: controller)));
  final context = tester.element(find.byType(ChatHome));
  Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NewChatPage(controller: controller)));
  await tester.pumpAndSettle();
}

Future<void> chooseFresh(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Available models'));
  await tester.tap(find.text('Available models'));
  await tester.pumpAndSettle();
  expect(find.text('hidden'), findsNothing);
  await tester.tap(find.text('Two · same').last);
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Start conversation'));
  expect(
      tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Start conversation'))
          .onPressed,
      isNotNull);
}

void main() {
  testWidgets(
      'old finisher after resume cannot clear a newer discovery; fresh page is blocked in background',
      (tester) async {
    final base = await makeStore();
    final secrets = DelayedSecrets();
    final oldSecret = Completer<String?>();
    final capability = Completer<http.Response>();
    var requests = 0;
    final controller = ChatController(
        SaathiStore(preferences: base.preferences, secrets: secrets),
        coreFactory: () => SaathiCore(client: MockClient((r) async {
              requests++;
              return r.url.path.endsWith('/capabilities')
                  ? await capability.future
                  : http.Response(enrichedCatalog, 200);
            })));
    await controller.load();
    await controller.addConnection({
      'id': 'h',
      'name': 'Hermes',
      'type': 'hermes',
      'url': 'http://localhost'
    }, 'synthetic');
    await mountPicker(tester, controller);
    secrets.gate = oldSecret;
    await tester.tap(find.text('Discover models'));
    await tester.pump();
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Discover models'))
            .onPressed,
        isNull);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    secrets.gate = null;
    await tester.runAsync(() async {
      await tester.tap(find.text('Discover models'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      oldSecret.complete('old');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    expect(requests, 1);
    expect(find.text('Discovering…'), findsOneWidget);
    capability.complete(http.Response(catalogCapabilities, 200));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    await chooseFresh(tester);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    final navigator = Navigator.of(tester.element(find.byType(NewChatPage)));
    navigator.pop();
    await tester.pumpAndSettle();
    navigator.push(MaterialPageRoute<void>(
        builder: (_) => NewChatPage(controller: controller)));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Discover models'))
            .onPressed,
        isNull);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(find.text('Available models'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
      'controller disposal finishes its picker loading without publishing catalog',
      (tester) async {
    final base = await makeStore();
    final secrets = DelayedSecrets();
    var requests = 0;
    final controller = ChatController(
        SaathiStore(preferences: base.preferences, secrets: secrets),
        coreFactory: () => SaathiCore(client: MockClient((r) async {
              requests++;
              return http.Response(catalogCapabilities, 200);
            })));
    await controller.load();
    await controller.addConnection({
      'id': 'h',
      'name': 'Hermes',
      'type': 'hermes',
      'url': 'http://localhost'
    }, 'synthetic');
    await tester
        .pumpWidget(MaterialApp(home: NewChatPage(controller: controller)));
    secrets.gate = Completer<String?>();
    await tester.tap(find.text('Discover models'));
    await tester.pump();
    controller.dispose();
    secrets.gate!.complete('old');
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.text('Discovering…'), findsNothing);
    expect(find.text('Available models'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  for (final boundary in ['secret', 'capability', 'catalog']) {
    testWidgets(
        'actual ChatHome pause/resume irreversibly revokes $boundary catalog',
        (tester) async {
      final base = await makeStore();
      final secrets = DelayedSecrets();
      final store =
          SaathiStore(preferences: base.preferences, secrets: secrets);
      final gate = Completer<http.Response>();
      final paths = <String>[];
      var delayed = true;
      final controller = ChatController(store,
          coreFactory: () => SaathiCore(client: MockClient((r) async {
                paths.add(r.url.path);
                if (delayed &&
                    ((boundary == 'capability' &&
                            r.url.path.endsWith('/capabilities')) ||
                        (boundary == 'catalog' &&
                            r.url.path.endsWith('/options')))) {
                  return gate.future;
                }
                return http.Response(
                    r.url.path.endsWith('/capabilities')
                        ? catalogCapabilities
                        : enrichedCatalog,
                    200);
              })));
      await controller.load();
      await controller.addConnection({
        'id': 'h',
        'name': 'Hermes',
        'type': 'hermes',
        'url': 'http://localhost'
      }, 'synthetic');
      await mountPicker(tester, controller);
      if (boundary == 'secret') secrets.gate = Completer<String?>();
      await tester.runAsync(() async {
        await tester.tap(find.text('Discover models'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      // Complete while backgrounded: neither secret nor capabilities may start
      // another request, and a completed catalog cannot become selectable.
      delayed = false;
      secrets.gate?.complete('synthetic');
      if (boundary != 'secret') {
        gate.complete(http.Response(
            boundary == 'capability' ? catalogCapabilities : enrichedCatalog,
            200));
      }
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      expect(
          paths.length,
          boundary == 'secret'
              ? 0
              : boundary == 'capability'
                  ? 1
                  : 2);
      expect(find.text('Available models'), findsNothing);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(find.text('Available models'), findsNothing);
      expect(find.text('Discovering…'), findsNothing);
      secrets.gate = null;
      await tester.runAsync(() async {
        await tester.tap(find.text('Discover models'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      await chooseFresh(tester);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  for (final replacement in ['key-map', 'source']) {
    for (final boundary in ['secret', 'capability']) {
      testWidgets(
          'picker $replacement replacement during $boundary releases loading and selects fresh tuple',
          (tester) async {
        final base = await makeStore();
        final secrets = DelayedSecrets();
        final store =
            SaathiStore(preferences: base.preferences, secrets: secrets);
        final gate = Completer<http.Response>();
        var delayed = true;
        final controller = ChatController(store,
            coreFactory: () => SaathiCore(client: MockClient((r) async {
                  if (delayed && boundary == 'capability') return gate.future;
                  return http.Response(
                      r.url.path.endsWith('/capabilities')
                          ? catalogCapabilities
                          : enrichedCatalog,
                      200);
                })));
        await controller.load();
        await controller.addConnection({
          'id': 'h',
          'name': 'Hermes',
          'type': 'hermes',
          'url': 'http://localhost'
        }, 'synthetic');
        await mountPicker(tester, controller);
        if (boundary == 'secret') secrets.gate = Completer<String?>();
        await tester.runAsync(() async {
          await tester.tap(find.text('Discover models'));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pump();
        final pendingSecret = secrets.gate;
        secrets.gate = null;
        await tester.runAsync(() => controller.updateConnection(
            'h',
            {
              'name': 'Replacement',
              'type': 'hermes',
              'url': replacement == 'source'
                  ? 'http://localhost:2345'
                  : 'http://localhost'
            },
            apiKey: 'replacement'));
        pendingSecret?.complete('old');
        delayed = false;
        if (boundary == 'capability') {
          gate.complete(http.Response(catalogCapabilities, 200));
        }
        await tester.pumpAndSettle();
        expect(find.text('Discovering…'), findsNothing);
        await tester.runAsync(() async {
          await tester.tap(find.text('Discover models'));
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pumpAndSettle();
        await chooseFresh(tester);
        await tester.tap(find.text('Start conversation'));
        await tester.pumpAndSettle();
        expect(controller.current!.upstreamProvider, 'two');
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });
    }
  }
}
