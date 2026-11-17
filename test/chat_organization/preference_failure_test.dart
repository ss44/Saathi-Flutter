import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/chat_organization/organization.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'false preference write keeps previous cache and retry retains candidate',
      () async {
    const channel = MethodChannel('plugins.flutter.io/shared_preferences');
    var failures = 0;
    final disk = <String, Object>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'getAll') return disk;
      if (call.method.startsWith('set')) {
        if (failures > 0) {
          failures--;
          return false;
        }
        disk[args!['key'] as String] = args['value'] as Object;
        return true;
      }
      if (call.method == 'remove') {
        disk.remove(args!['key']);
        return true;
      }
      return true;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final prefs = await SharedPreferences.getInstance();
    final organization = ChatOrganization(OrganizationStorage(prefs));
    await organization.load();
    const id = ConversationIdentity('original', 'chat');
    await organization.edit(id,
        displayName: 'Before',
        personaId: null,
        policy: PersonaEditPolicy.localInstructions,
        pendingReason: null);
    final before = prefs.getString(OrganizationStorage.key);
    failures = 1;
    await expectLater(
        organization.edit(id,
            displayName: 'After',
            personaId: null,
            policy: PersonaEditPolicy.localInstructions,
            pendingReason: null),
        throwsStateError);
    expect(organization.entry(id).displayName, 'Before');
    expect(organization.hasUnsavedChanges, isTrue);
    expect(prefs.getString(OrganizationStorage.key), before);
    await organization.retrySave();
    expect(organization.entry(id).displayName, 'After');
    expect(
        jsonDecode(prefs.getString(OrganizationStorage.key)!)['chats']
            [id.storageKey]['displayName'],
        'After');
    expect(organization.hasUnsavedChanges, isFalse);
  });
}
