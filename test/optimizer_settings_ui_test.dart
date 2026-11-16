import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/optimizer_settings.dart';
import 'prompt_optimizer_acceptance_test.dart' as fixture;

void main() {
  testWidgets('standalone global picker revokes on actual lifecycle round trip',
      (tester) async {
    final pending = Completer<http.Response>();
    final c = await fixture.controller(MemorySecrets(), (_) => pending.future,
        catalogFixture: false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: OptimizerSettingsButton(controller: c))));
    await tester.tap(find.byTooltip('Global prompt optimizer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direct'));
    await tester.pump();
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    pending.complete(http.Response(
        jsonEncode({
          'data': [
            {'id': 'stale'}
          ]
        }),
        200));
    await fixture.flush(tester);
    expect(find.text('stale'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  for (final width in [360.0, 390.0]) {
    testWidgets(
        '$width grouped chat override and explicit inheritance at 2x with keyboard',
        (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requests = <http.Request>[];
      final c = await fixture.controller(MemorySecrets(), (request) async {
        requests.add(request);
        return http.Response(
            jsonEncode({
              'data': [
                {'id': 'same-model'}
              ]
            }),
            200);
      }, catalogFixture: false);
      c.connections.addAll([
        {
          'id': 'second',
          'name': 'Second connection',
          'type': 'openai',
          'url': 'http://localhost:9998'
        },
        {
          'id': 'native',
          'name': 'Native Hermes',
          'type': 'hermes',
          'url': 'http://localhost:9997'
        },
      ]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(2),
                  viewInsets: const EdgeInsets.only(bottom: 280)),
              child: child!),
          home: ChatHome(controller: c)));
      await tester.tap(find.byTooltip('Chat prompt optimizer'));
      await tester.pumpAndSettle();
      expect(find.text('Inheriting global setting'), findsOneWidget);
      await Scrollable.ensureVisible(
          tester.element(find.text('Second connection')),
          alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second connection'));
      await fixture.flush(tester);
      await Scrollable.ensureVisible(tester.element(find.text('same-model')),
          alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(find.text('same-model'));
      await tester.pumpAndSettle();
      expect(
          c.optimizerOverride(c.current!),
          const OptimizerSelection(
              connectionId: 'second', model: 'same-model'));
      expect(c.globalOptimizerSelection,
          const OptimizerSelection(connectionId: 'direct', model: 'test'));
      expect(c.current!.model, 'test');
      expect(requests.single.url.port, 9998);
      expect(requests.single.method, 'GET');
      await tester.tap(find.byTooltip('Chat prompt optimizer'));
      await tester.pumpAndSettle();
      expect(find.text('Override for this chat'), findsOneWidget);
      expect(find.text('Selected: Second connection · same-model'),
          findsOneWidget);
      await Scrollable.ensureVisible(
          tester.element(find.text('Inherit global setting')),
          alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inherit global setting'));
      await tester.pumpAndSettle();
      expect(c.optimizerOverride(c.current!), isNull);
      expect(c.optimizerSelection(c.current), c.globalOptimizerSelection);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
  testWidgets(
      'native connection stays visible but never discovers or runs agent tools',
      (tester) async {
    var requests = 0;
    final c = await fixture.controller(MemorySecrets(), (_) async {
      requests++;
      return http.Response('{}', 200);
    }, catalogFixture: false);
    c.connections
        .add({'id': 'native', 'name': 'Native Hermes', 'type': 'hermes'});
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: OptimizerSettingsButton(controller: c))));
    await tester.tap(find.byTooltip('Global prompt optimizer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Native Hermes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bounded text-only rewrite unavailable'),
        findsOneWidget);
    expect(requests, 0);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  for (final action in ['source', 'lifecycle', 'dispose', 'owner']) {
    testWidgets(
        '$action during catalog rejects stale data and allows fresh picker',
        (tester) async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final c = await fixture.controller(MemorySecrets(), (_) {
        calls++;
        return calls == 1
            ? pending.future
            : Future.value(http.Response(
                jsonEncode({
                  'data': [
                    {'id': 'fresh'}
                  ]
                }),
                200));
      }, catalogFixture: false);
      final visible = ValueNotifier(true);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ValueListenableBuilder<bool>(
                  valueListenable: visible,
                  builder: (_, shown, child) => shown
                      ? OptimizerSettingsButton(controller: c)
                      : const SizedBox()))));
      await tester.tap(find.byTooltip('Global prompt optimizer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Direct'));
      await tester.pump();
      if (action == 'source') {
        c.connections[0] = {...c.connections[0]};
        c.notifyListeners();
      } else if (action == 'lifecycle') {
        c.setQueueBackground(true);
        c.setQueueBackground(false);
        c.notifyListeners();
      } else if (action == 'owner') {
        visible.value = false;
        await tester.pump();
      } else {
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
      pending.complete(http.Response(
          jsonEncode({
            'data': [
              {'id': 'stale'}
            ]
          }),
          200));
      await fixture.flush(tester);
      expect(find.text('stale'), findsNothing);
      if (action != 'dispose') {
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
      visible.value = true;
      await tester.pump();
      await tester.tap(find.byTooltip('Global prompt optimizer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Direct'));
      await fixture.flush(tester);
      await tester.tap(find.text('fresh'));
      await tester.pumpAndSettle();
      expect(c.globalOptimizerSelection!.model, 'fresh');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
}
