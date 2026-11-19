import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/canonical_connection.dart';
import 'package:saathi/gateway/hermes_gateway.dart';

import '../ui/remote_participation_test.dart'
    show ParticipationFixture, network;
import 'canonical_combined_controller_test.dart' show NativeHost;

void main() {
  testWidgets('paused native chat reconnects its original profile and session',
      (t) async {
    HttpOverrides.global = null;
    final f = ParticipationFixture();
    final native = NativeHost();
    await t.runAsync(() async {
      await f.start();
      await native.start();
      await f.controller.addConnection({
        'id': 'native',
        'name': 'Original native host',
        'type': 'hermesGateway',
        'url': native.url,
      }, '');
      await f.controller
          .connectCanonical(f.controller.connections.last, native.invite);
      await f.controller.attachCanonical(
          GatewaySession({'session_id': 'chat', 'title': 'Native A'}));
    });
    addTearDown(f.controller.dispose);
    addTearDown(native.close);
    final original = f.controller.current;
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(360, 800);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(2),
          viewInsets: const EdgeInsets.only(bottom: 220),
        ),
        child: child!,
      ),
      home: ChatHome(controller: f.controller),
    ));
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      t.binding.handleAppLifecycleStateChanged(state);
      await t.pump();
    }
    await network(t);
    expect(f.controller.readOnly, isTrue);
    expect(find.textContaining('removed or changed'), findsNothing);
    await t.scrollUntilVisible(find.text('Reconnect to original host'), 100,
        scrollable: find
            .descendant(
                of: find.byKey(const Key('chat-feedback')),
                matching: find.byType(Scrollable))
            .first);
    await t.pumpAndSettle();
    expect(
        find.text('Reconnect to original host').hitTestable(), findsOneWidget);
    expect(f.controller.canChangeConnections, isTrue);
    expect(
        t
            .widget<TextButton>(
                find.widgetWithText(TextButton, 'Reconnect to original host'))
            .onPressed,
        isNotNull);
    await t.tap(find.text('Reconnect to original host'));
    await network(t);
    expect(find.byType(CanonicalConnectionPage), findsOneWidget);
    // At 2x text with the keyboard visible, later lazy form children need
    // real scrolling before their widgets exist or can receive input.
    final formScroll = find
        .descendant(
            of: find.byType(CanonicalConnectionPage),
            matching: find.byType(Scrollable))
        .first;
    await t.scrollUntilVisible(
        find.byKey(const Key('gateway-trusted-url')), 150,
        scrollable: formScroll);
    await t.pumpAndSettle();
    expect(
        t
            .widget<TextField>(find.byKey(const Key('gateway-trusted-url')))
            .readOnly,
        isTrue);
    expect(
        t
            .widget<TextField>(find.byKey(const Key('gateway-trusted-url')))
            .controller!
            .text,
        native.url);
    final inviteField =
        find.widgetWithText(TextField, 'Host-issued invite JSON');
    await t.scrollUntilVisible(inviteField, 150, scrollable: formScroll);
    await t.pumpAndSettle();
    expect(inviteField.hitTestable(), findsOneWidget);
    await t.enterText(inviteField, native.invite);
    await t.scrollUntilVisible(find.text('Trust this host and connect'), 150,
        scrollable: find
            .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable))
            .first);
    await t.pumpAndSettle();
    expect(
        find.text('Trust this host and connect').hitTestable(), findsOneWidget);
    await t.runAsync(() => t.tap(find.text('Trust this host and connect')));
    await network(t);
    await t.pumpAndSettle();
    expect(identical(f.controller.current, original), isTrue);
    expect(f.controller.current!.canonicalProfileId, 'profile');
    expect(f.controller.readOnly, isFalse);
    expect(find.byKey(const Key('composer')).hitTestable(), findsOneWidget);
    expect(
        native.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
    await t.pumpWidget(const SizedBox());
    await network(t);
  });

  testWidgets('gateway recovery from REST history opens the attached composer',
      (t) async {
    HttpOverrides.global = null;
    final f = ParticipationFixture()..source = 'desktop';
    final native = NativeHost();
    await t.runAsync(() async {
      await f.start();
      await native.start();
    });
    addTearDown(f.controller.dispose);
    addTearDown(native.close);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: f.controller)));
    await t.tap(find.byTooltip('Open navigation menu'));
    await network(t);
    await t.tap(find.text('External chat'));
    await network(t);
    await t.tap(find.text('Connect to original host'));
    await network(t);
    await t.enterText(find.byKey(const Key('gateway-trusted-url')), native.url);
    await t.enterText(find.widgetWithText(TextField, 'Host-issued invite JSON'),
        native.invite);
    await t.scrollUntilVisible(find.text('Trust this host and connect'), 150,
        scrollable: find
            .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable))
            .first);
    await t.pumpAndSettle();
    expect(
        find.text('Trust this host and connect').hitTestable(), findsOneWidget);
    await t.runAsync(() => t.tap(find.text('Trust this host and connect')));
    Future<void> waitForState(bool Function() ready, String description) async {
      for (var i = 0; i < 200; i++) {
        // TLS/RPC replies need real I/O; their UI continuations need frames.
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump(const Duration(milliseconds: 30));
        if (ready()) return;
      }
      fail('Timed out waiting for $description. '
          'Requests=${native.requests.map((r) => r['method']).toList()} '
          'UI=${t.widgetList<Text>(find.byType(Text)).map((w) => w.data).join(' | ')}');
    }

    final connectionPage = find.byType(CanonicalConnectionPage);
    final connectButton = find.descendant(
        of: connectionPage,
        matching:
            find.widgetWithText(FilledButton, 'Trust this host and connect'));
    // Negotiation and both live/stored lists must finish before lazy scrolling.
    // Request receipt alone does not prove the reply has reached the widget.
    await waitForState(
        () =>
            native.requests
                .where((r) => r['method'] == 'session.list')
                .map((r) => r['params']['scope'])
                .toSet()
                .containsAll(['live', 'stored']) &&
            connectButton.evaluate().length == 1 &&
            t.widget<FilledButton>(connectButton).onPressed != null,
        'the connection form to finish both session lists');
    expect(find.textContaining('Could not connect.'), findsNothing);
    // EditableText has its own horizontal Scrollable; use the form's owner.
    final formScroll = find
        .descendant(
            of: find.descendant(
                of: connectionPage, matching: find.byType(ListView)),
            matching: find.byType(Scrollable))
        .first;
    await t.scrollUntilVisible(find.text('Native A'), 150,
        scrollable: formScroll);
    expect(find.text('Native A'), findsOneWidget,
        reason: 'Requests=${native.requests.map((r) => r['method']).toList()} '
            'UI=${t.widgetList<Text>(find.byType(Text)).map((w) => w.data).join(' | ')}');
    await t.ensureVisible(find.text('Native A'));
    await t.pumpAndSettle();
    await t.tap(find.text('Native A'));
    await waitForState(
        () =>
            f.controller.canonical?.connected == true &&
            connectionPage.evaluate().isEmpty &&
            find.byKey(const Key('composer')).hitTestable().evaluate().length ==
                1,
        'the attached native composer');
    await t.pumpAndSettle();
    expect(f.controller.current?.remoteSessionId, 'chat');
    expect(f.controller.current?.canonicalProfileId, 'profile');
    expect(f.controller.current?.connectionId, isNot('h'));
    expect(f.controller.readOnly, isFalse);
    expect(find.byKey(const Key('composer')).hitTestable(), findsOneWidget);
    expect(find.text('Gateway connection required'), findsNothing);
    expect(
        native.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
    expect(f.requests.every((r) => r.method == 'GET'), isTrue);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await network(t);
  });
}
