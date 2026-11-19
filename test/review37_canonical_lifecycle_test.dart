import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';

import 'gateway/canonical_combined_controller_test.dart' as fixture;

class LifecycleHost extends fixture.NativeHost {
  String status = 'started';
  String outcome = 'completed';
  @override
  Map<String, dynamic> receipt() => {
        ...super.receipt(),
        'status': status,
        if (status == 'terminal') 'outcome': outcome,
      };
}

Future<ChatController> setup(LifecycleHost host) async {
  await host.start();
  SharedPreferences.setMockInitialValues({});
  final c = ChatController(SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySecrets()));
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
  await c.attachCanonical(
      GatewaySession({'session_id': 'chat', 'title': 'Native A'}));
  await c.send('first');
  return c;
}

void main() {
  for (final state in [
    'queued',
    'started',
    'unknown',
    'completed',
    'failed',
    'cancelled',
    'interrupted'
  ]) {
    test(
        'native $state receipt owns thinking even after informational feedback',
        () async {
      final host = LifecycleHost();
      final c = await setup(host);
      final owner = c.canonical!;
      final input = owner.pendingInputId;
      expect(await owner.control('steer', text: 'guide'), isTrue);
      expect(owner.problem, contains('Guidance accepted'));
      expect(c.showPendingThinking, isTrue);
      host.delta('x' * (256 * 1024 + 1));
      final clock = Stopwatch()..start();
      while (!(owner.problem?.contains('preview limit') ?? false) &&
          clock.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(owner.problem, contains('preview limit'));
      expect(c.showPendingThinking, isTrue);
      host.terminal =
          ['completed', 'failed', 'cancelled', 'interrupted'].contains(state);
      host.status = host.terminal ? 'terminal' : state;
      host.outcome = state;
      await owner.refresh();
      expect(owner.pendingInputId, input);
      expect(owner.pendingRun!.sessionId, 'chat');
      expect(owner.pendingRun!.profileId, 'profile');
      expect(owner.pendingRun!.admissionId, 'run');
      expect(c.showPendingThinking, ['queued', 'started'].contains(state));
      expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
          hasLength(1));
      if (state == 'unknown') {
        expect(owner.problem, contains('not confirmed'));
        expect(owner.problem, contains('preview limit'));
      }
    });
  }
  for (final action in ['steer', 'redirect', 'interrupt']) {
    test('native $action feedback preserves its distinct control lifetime',
        () async {
      final host = LifecycleHost();
      final c = await setup(host);
      final owner = c.canonical!;
      expect(
          await owner.control(action,
              text: action == 'interrupt' ? null : 'guide'),
          isTrue);
      expect(owner.pendingRun!.state, GatewayRunState.running);
      expect(c.runPending, isTrue);
      expect(c.showPendingThinking, action != 'interrupt');
      expect(
          owner.problem,
          contains(
              action == 'interrupt' ? 'Stop requested' : 'Guidance accepted'));
      expect(host.requests.where((r) => r['method'] == 'session.$action'),
          hasLength(1));
      expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
          hasLength(1));
    });
  }
  for (final kind in ['approval', 'clarify']) {
    test('$kind decision suppresses thinking despite prior Guide notice',
        () async {
      final host = LifecycleHost();
      final c = await setup(host);
      final owner = c.canonical!;
      expect(await owner.control('steer', text: 'guide'), isTrue);
      host.prompts = [
        {
          'kind': kind,
          'prompt_id': 'request',
          'execution_generation': 4,
          'question': 'Your decision',
          if (kind == 'approval') 'command': 'pwd',
          if (kind == 'approval') 'choices': ['once', 'deny'],
        }
      ];
      await owner.refresh();
      expect(owner.pendingRun!.state, GatewayRunState.running);
      expect(owner.needsUserAction, isTrue);
      expect(c.showPendingThinking, isFalse);
      expect(await owner.control('steer', text: 'must not send'), isFalse);
      expect(host.requests.where((r) => r['method'] == 'session.steer'),
          hasLength(1));
      host.prompts = [];
      await owner.refresh();
      expect(c.showPendingThinking, isTrue);
      owner.suspend();
      expect(c.showPendingThinking, isFalse);
      expect(await owner.control('steer', text: 'revoked'), isFalse);
      expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
          hasLength(1));
    });
  }
}
