import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'unconfirmed rollback keeps settings recovery blocked until explicit retry',
      () async {
    const channel = MethodChannel('plugins.flutter.io/shared_preferences');

    final disk = <String, Object>{};
    var failing = true;
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'getAll') return Map<String, Object>.from(disk);
      if (call.method.startsWith('set')) {
        disk[args!['key'] as String] = args['value'] as Object;
        return args['key'] != 'flutter.${OrganizationStorage.key}' || !failing;
      }
      if (call.method == 'remove') {
        if (args!['key'] == 'flutter.${OrganizationStorage.key}' && failing) {
          return false;
        }
        disk.remove(args['key']);
      }
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      SharedPreferences.setMockInitialValues({});
    });
    final preferences = await SharedPreferences.getInstance();
    final c = ChatController(
        SaathiStore(preferences: preferences, secrets: MemorySecrets()));
    await c.load();
    await c.addConnection(
        {'id': 'original', 'name': 'Original', 'type': 'openai'}, '');
    await c.newSession(c.connections.single, 'original-model', '');
    final original = c.current!;
    final identity = c.identityOf(original);
    final organization = c.organization;
    await expectLater(
        c.saveChatSettings(original,
            originalConnection: c.connections.single,
            selection: c.selectionGeneration,
            model: 'candidate',
            instructions: '',
            personaId: null),
        throwsStateError);
    expect(organization.entry(identity).replyModel, isNull);
    expect(organization.hasUnsavedChanges, isTrue);
    expect(organization.error, isNotNull);
    await c.newSession(c.connections.single, 'other-model', '');
    failing = false;
    await organization.retrySave();
    expect(organization.hasUnsavedChanges, isFalse);
    expect(organization.entry(identity).replyModel, 'candidate');
    expect(c.replyModel(c.current!), 'other-model');
    c.dispose();
  });
}
