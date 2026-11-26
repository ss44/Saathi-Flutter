import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/connections.dart';
import 'package:saathi/ui/optimizer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'controller_http_test.dart' show makeStore;

Future<ChatController> _mountHome(
  WidgetTester t, {
  required Size size,
  String connectionType = 'openai',
  bool createSession = true,
  double textScale = 1,
  double keyboardInset = 0,
  http.Client? client,
  SaathiStore? store,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  t.view.viewInsets = FakeViewPadding(bottom: keyboardInset);
  addTearDown(t.view.reset);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final c = ChatController(
    store ?? await makeStore(),
    coreFactory: client == null ? null : () => SaathiCore(client: client),
  );
  await c.load();
  await c.addConnection({
    'id': 'source-1',
    'name': 'Primary Fixture',
    'type': connectionType,
    'url': 'https://example.test',
  }, 'fixture-key');
  if (createSession) {
    await c.newSession(
      c.connections.single,
      'initial-model',
      'Initial instructions',
    );
  }
  await t.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        viewInsets: EdgeInsets.only(bottom: keyboardInset),
      ),
      child: child!,
    ),
    home: ChatHome(controller: c),
  ));
  await t.pumpAndSettle();
  addTearDown(() async {
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  return c;
}

void main() {
  testWidgets(
      'compact and wide toolbars use distinct Settings and Chat settings icons',
      (t) async {
    await _mountHome(t, size: const Size(390, 844));
    IconButton iconButtonWithTooltip(String tooltip) => t.widget<IconButton>(
          find.byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == tooltip,
          ),
        );
    final settingsBtn = iconButtonWithTooltip('Settings');
    final chatSettingsBtn = iconButtonWithTooltip('Chat settings');
    expect((settingsBtn.icon as Icon).icon, Icons.settings_outlined);
    expect((chatSettingsBtn.icon as Icon).icon, Icons.tune_rounded);

    // Tapping global Settings opens ConnectionsPage, not ChatSettingsPanel.
    await t.tap(find.byTooltip('Settings'));
    await t.pumpAndSettle();
    expect(find.byType(ConnectionsPage), findsOneWidget);
    expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
    await t.pageBack();
    await t.pumpAndSettle();

    // Tapping Chat settings opens unified ChatSettingsPanel on mobile.
    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsOneWidget);
    await t.tap(find.widgetWithText(TextButton, 'Cancel'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsNothing);

    // Resize to wide desktop layout: rail holds Settings, AppBar holds Chat settings.
    t.view.physicalSize = const Size(1440, 900);
    await t.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byTooltip('Settings'), findsNothing);
    final wideChatBtn = iconButtonWithTooltip('Chat settings');
    expect((wideChatBtn.icon as Icon).icon, Icons.tune_rounded);
    expect(t.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'mobile unified chat settings edits name, discovered model, persona, instructions, and optimizer',
      (t) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET' && request.url.path.endsWith('/models')) {
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'discovered-alpha'},
              {'id': 'discovered-beta'},
            ],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'Fixture reply'},
            },
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);
    final store = await makeStore();
    final c = await _mountHome(
      t,
      size: const Size(390, 844),
      client: client,
      store: store,
    );
    final session = c.current!;
    final originalConnection = c.connections.single;
    await t.enterText(find.byKey(const Key('composer')), 'Keep mobile draft');
    await t.pump();

    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsOneWidget);
    expect(requests, isEmpty,
        reason: 'Opening chat settings must not issue network requests');

    // 1. Display name
    await t.enterText(
        find.byKey(const Key('chat-display-name')), 'Mobile chat');

    // 2. Optional model discovery for direct connection
    final discoverButton = find.byKey(const Key('chat-discover-models'));
    await t.ensureVisible(discoverButton);
    await t.tap(discoverButton);
    for (var i = 0;
        i < 15 &&
            find.byKey(const Key('chat-discovered-models')).evaluate().isEmpty;
        i++) {
      await t.pump();
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await t.pumpAndSettle();
    expect(requests.map((r) => r.method), ['GET']);
    final picker = find.byKey(const Key('chat-discovered-models'));
    expect(picker, findsOneWidget);
    await t.ensureVisible(picker);
    await t.tap(picker);
    await t.pumpAndSettle();
    await t.tap(find.text('discovered-beta').last);
    await t.pumpAndSettle();
    expect(
      t
          .widget<TextField>(find.byKey(const Key('chat-reply-model')))
          .controller!
          .text,
      'discovered-beta',
    );
    // Discovery/selection never saves automatically.
    expect(c.replyModel(session), 'initial-model');

    // 3. Shared persona create + edit
    final newPersona = find.widgetWithText(TextButton, 'New persona');
    await t.ensureVisible(newPersona);
    await t.tap(newPersona);
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('persona-name')), 'Mentor');
    await t.enterText(
      find.byKey(const ValueKey('persona-instructions')),
      'Be concise.',
    );
    await t.tap(find.text('Save persona'));
    await t.pumpAndSettle();
    expect(
      t.widget<TextField>(find.byKey(const Key('chat-instructions'))).enabled,
      isFalse,
    );
    expect(
      t
          .widget<TextField>(find.byKey(const Key('chat-instructions')))
          .controller!
          .text,
      'Be concise.',
    );

    final editPersona = find.widgetWithText(TextButton, 'Edit shared persona');
    await t.ensureVisible(editPersona);
    await t.tap(editPersona);
    await t.pumpAndSettle();
    await t.enterText(
      find.byKey(const ValueKey('persona-instructions')),
      'Be concise and direct.',
    );
    await t.tap(find.text('Save persona'));
    await t.pumpAndSettle();
    expect(
      t
          .widget<TextField>(find.byKey(const Key('chat-instructions')))
          .controller!
          .text,
      'Be concise and direct.',
    );

    // Switch back to chat-only instructions and edit them.
    final personaPicker = find.byKey(const Key('chat-persona'));
    await t.ensureVisible(personaPicker);
    await t.tap(personaPicker);
    await t.pumpAndSettle();
    await t.tap(find.text('This chat’s instructions').last);
    await t.pumpAndSettle();
    final instructions = find.byKey(const Key('chat-instructions'));
    await t.ensureVisible(instructions);
    await t.enterText(instructions, 'Custom mobile instructions');

    // 4. Per-chat prompt optimizer override from unified settings
    final optimizerTile =
        find.widgetWithText(ListTile, 'Chat prompt optimizer');
    await t.ensureVisible(optimizerTile);
    await t.tap(optimizerTile);
    await t.pumpAndSettle();
    await t.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('Primary Fixture'),
    ));
    for (var i = 0;
        i < 15 && find.text('discovered-alpha').evaluate().isEmpty;
        i++) {
      await t.pump();
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await t.pumpAndSettle();
    await t.tap(find.text('discovered-alpha'));
    await t.pumpAndSettle();
    expect(c.optimizerOverride(session)?.model, 'discovered-alpha');

    // 5. Explicit Save commits name, model, and instructions atomically.
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
    expect(c.displayTitle(session), 'Mobile chat');
    expect(c.replyModel(session), 'discovered-beta');
    expect(
      c.organization
          .captureInstructions(c.identityOf(session), fallback: '')
          .instructions,
      'Custom mobile instructions',
    );
    expect(c.connections.single, same(originalConnection));
    expect(
      t.widget<TextField>(find.byKey(const Key('composer'))).controller!.text,
      'Keep mobile draft',
    );
    expect(requests.where((r) => r.method == 'POST'), isEmpty);

    // Next send uses committed model and instructions on the original connection.
    expect(await t.runAsync(() => c.send('Hello mobile')), isTrue);
    final post = requests.singleWhere((r) => r.method == 'POST');
    final body = jsonDecode(post.body) as Map;
    expect(body['model'], 'discovered-beta');
    expect(
      (body['messages'] as List).first['content'],
      'Custom mobile instructions',
    );
    expect(post.url.host, 'example.test');
    expect(t.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'native session stays read-only on mobile while allowing local display rename',
      (t) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('Unexpected network request', 500);
    });
    addTearDown(client.close);
    final c = await _mountHome(
      t,
      size: const Size(390, 844),
      connectionType: 'hermes',
      client: client,
    );
    final session = c.current!;

    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsOneWidget);
    expect(
      t.widget<TextField>(find.byKey(const Key('chat-reply-model'))).enabled,
      isFalse,
    );
    expect(
      t.widget<TextField>(find.byKey(const Key('chat-instructions'))).enabled,
      isFalse,
    );
    expect(find.byKey(const Key('chat-discover-models')), findsNothing);
    expect(find.textContaining('no verified contract'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
    );

    // Local display rename is still supported without touching server config.
    await t.enterText(
      find.byKey(const Key('chat-display-name')),
      'Local Hermes label',
    );
    await t.pumpAndSettle();
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNotNull,
    );
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
    expect(c.displayTitle(session), 'Local Hermes label');
    expect(c.replyModel(session), 'initial-model');
    expect(requests, isEmpty);
    expect(t.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'mobile Cancel and Back discard unsaved edits and failed save retries storage only',
      (t) async {
    const channel = MethodChannel('plugins.flutter.io/shared_preferences');
    final disk = <String, Object>{};
    var failNext = false;
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'getAll') return Map<String, Object>.from(disk);
      if (call.method.startsWith('set')) {
        disk[args!['key'] as String] = args['value'] as Object;
        if (args['key'] == 'flutter.${OrganizationStorage.key}' && failNext) {
          failNext = false;
          return false;
        }
      } else if (call.method == 'remove') {
        disk.remove(args!['key']);
      }
      return true;
    });
    addTearDown(() {
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      SharedPreferences.setMockInitialValues({});
    });
    var networkCalls = 0;
    final client = MockClient((_) async {
      networkCalls++;
      return http.Response('Unexpected', 500);
    });
    addTearDown(client.close);
    final store = SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySecrets(),
    );
    final c = await _mountHome(
      t,
      size: const Size(390, 844),
      store: store,
      client: client,
    );

    // System Back closes compact sheet without saving.
    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('chat-reply-model')), 'discarded');
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
    expect(c.replyModel(c.current!), 'initial-model');

    // Failed save retains draft and succeeds on explicit storage-only retry.
    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    await t.enterText(
      find.byKey(const Key('chat-display-name')),
      'Retried title',
    );
    await t.enterText(
      find.byKey(const Key('chat-reply-model')),
      'retried-model',
    );
    failNext = true;
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await t.pumpAndSettle();
    expect(find.textContaining('Chat settings were not saved'), findsOneWidget);
    expect(c.replyModel(c.current!), 'initial-model');
    expect(
      t
          .widget<TextField>(find.byKey(const Key('chat-reply-model')))
          .controller!
          .text,
      'retried-model',
    );
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
    expect(c.displayTitle(c.current!), 'Retried title');
    expect(c.replyModel(c.current!), 'retried-model');
    expect(networkCalls, 0);
    expect(t.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'small-screen 360px at 2x text with keyboard keeps chat settings usable',
      (t) async {
    final c = await _mountHome(
      t,
      size: const Size(360, 800),
      textScale: 2,
      keyboardInset: 300,
    );
    final chatSettings = find.byTooltip('Chat settings');
    final globalSettings = find.byTooltip('Settings');
    expect(chatSettings, findsOneWidget);
    expect(globalSettings, findsOneWidget);
    expect(t.getSize(chatSettings).width, greaterThanOrEqualTo(48));
    expect(t.getSize(chatSettings).height, greaterThanOrEqualTo(48));
    expect(t.getSize(globalSettings).width, greaterThanOrEqualTo(48));
    expect(t.getSize(globalSettings).height, greaterThanOrEqualTo(48));
    expect(t.takeException(), isNull);

    await t.tap(chatSettings);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsOneWidget);
    final nameField = find.byKey(const Key('chat-display-name'));
    await t.ensureVisible(nameField);
    await t.enterText(nameField, 'Compact 360');
    final modelField = find.byKey(const Key('chat-reply-model'));
    await t.ensureVisible(modelField);
    await t.enterText(modelField, 'compact-model');
    final saveButton = find.widgetWithText(FilledButton, 'Save');
    expect(saveButton.hitTestable(), findsOneWidget);
    await t.tap(saveButton);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
    expect(c.displayTitle(c.current!), 'Compact 360');
    expect(c.replyModel(c.current!), 'compact-model');
    expect(t.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('no active session hides Chat settings while keeping Settings',
      (t) async {
    await _mountHome(
      t,
      size: const Size(390, 844),
      createSession: false,
    );
    expect(find.byTooltip('Chat settings'), findsNothing);
    final settingsBtn = t.widget<IconButton>(
      find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Settings',
      ),
    );
    expect((settingsBtn.icon as Icon).icon, Icons.settings_outlined);
    expect(t.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
