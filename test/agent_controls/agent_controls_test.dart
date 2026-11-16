import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/agent_controls/agent_controls.dart';

Map<String, Object?> approval({int generation = 3}) => {
      'kind': 'approval',
      'prompt_id': 'p',
      'execution_generation': generation,
      'command': 'echo hello',
      'description': 'Print a greeting',
      'choices': ['once', 'deny', 'always'],
      'timeout_s': 0,
    };
Map<String, Object?> run(List<Object?> controls) => {
      'run_id': 'r',
      'execution_generation': 3,
      'status': 'running',
      'pending_controls': controls,
    };
void main() {
  for (final mutation in [
    'expired',
    'generation',
    'kind',
    'choice',
    'command',
    'wrongRun',
    'wrongSource',
    'revision'
  ]) {
    test('no post after authoritative $mutation change', () async {
      final h = Harness();
      await h.c.refresh();
      final p = h.c.snapshot!.controls.single;
      switch (mutation) {
        case 'expired':
          h.data = run([]);
          break;
        case 'generation':
          h.data = {
            ...run([approval(generation: 4)]),
            'execution_generation': 4
          };
          break;
        case 'kind':
          h.data = run([
            {
              'kind': 'clarify',
              'prompt_id': 'p',
              'execution_generation': 3,
              'question': 'Where?',
              'choices': ['once']
            }
          ]);
          break;
        case 'choice':
          h.data = run([
            {
              ...approval(),
              'choices': ['deny']
            }
          ]);
          break;
        case 'command':
          h.data = run([
            {...approval(), 'command': 'different action'}
          ]);
          break;
        case 'wrongRun':
          h.data = {
            ...run([approval()]),
            'run_id': 'foreign'
          };
          break;
        case 'wrongSource':
          h.returnScope = ControlScope(
              sourceId: 'other',
              runId: 'r',
              authorityToken: h.scope.authorityToken);
          break;
        case 'revision':
          h.current = false;
          break;
      }
      await h.c.decide(p, 'once');
      expect(h.posts, isEmpty);
      h.c.dispose();
    });
  }
  test('coalesces multiple clicks and refuses after disposal during refresh',
      () async {
    final h = Harness();
    await h.c.refresh();
    final p = h.c.snapshot!.controls.single;
    h.gate = Completer<void>();
    final a = h.c.decide(p, 'once');
    final b = h.c.decide(p, 'deny');
    h.c.dispose();
    h.gate!.complete();
    await Future.wait([a, b]);
    expect(h.posts, isEmpty);
  });
  test('coalesces live multiple clicks into one post', () async {
    final h = Harness();
    await h.c.refresh();
    final p = h.c.snapshot!.controls.single;
    h.gate = Completer<void>();
    final a = h.c.decide(p, 'once');
    final b = h.c.decide(p, 'deny');
    h.gate!.complete();
    await Future.wait([a, b]);
    expect(h.posts.length, 1);
    h.c.dispose();
  });
  test('connection map revision changes during refresh prevent post', () async {
    final h = Harness();
    await h.c.refresh();
    final p = h.c.snapshot!.controls.single;
    h.gate = Completer<void>();
    final a = h.c.decide(p, 'once');
    h.current = false;
    h.gate!.complete();
    await a;
    expect(h.posts, isEmpty);
    h.c.dispose();
  });
  test('409 refreshes canonical state and notifies parent', () async {
    final h = Harness();
    h.result = const ControlPostResult(409, {});
    await h.c.refresh();
    await h.c.decide(h.c.snapshot!.controls.single, 'deny');
    expect(h.reads, 3);
    expect(h.reason, ControlRefreshReason.conflict);
    expect(h.c.message, contains('answered elsewhere'));
    h.c.dispose();
  });
  test('foreign or malformed success ack is never called completion', () async {
    for (final body in [
      {'run_id': 'foreign', 'prompt_id': 'p', 'status': 'resolved'},
      {'run_id': 'r', 'prompt_id': 'other', 'status': 'resolved'},
      {'run_id': 'r', 'prompt_id': 'p', 'status': 'completed'}
    ]) {
      final h = Harness();
      h.result = ControlPostResult(200, body);
      await h.c.refresh();
      await h.c.decide(h.c.snapshot!.controls.single, 'once');
      expect(h.reason, isNull);
      expect(h.c.message, contains('not confirmed'));
      h.c.dispose();
    }
  });
  test('unsupported action and unreturned or always choices never post',
      () async {
    final h = Harness();
    await h.c.refresh();
    final p = h.c.snapshot!.controls.single;
    await h.c.decide(p, 'always');
    await h.c.decide(p, 'session');
    await h.c.decide(p, 'unknown');
    h.supported = false;
    await h.c.decide(p, 'once');
    expect(h.posts, isEmpty);
    h.c.dispose();
  });
  test('rejects malformed controls and duplicate identities safely', () {
    final h = Harness();
    for (final bad in [
      null,
      {},
      {...approval(), 'execution_generation': 3.0},
      {
        ...approval(),
        'choices': [3]
      },
      {...approval(), 'kind': 'tool'},
      {...approval(), 'prompt_id': ''}
    ]) {
      final s = PendingControlsSnapshot.fromJson(h.scope, run([bad]));
      expect(s.controls, isEmpty);
      expect(s.hasMalformedControls, isTrue);
    }
    expect(
        PendingControlsSnapshot.fromJson(h.scope, run([approval(), approval()]))
            .controls,
        isEmpty);
    for (final cmd in [null, 'x' * 2001, '{"tool":"raw"}']) {
      final p = PendingControlsSnapshot.fromJson(
          h.scope,
          run([
            {...approval(), 'command': cmd}
          ])).controls.single;
      expect(p.accepts('once'), isFalse);
      expect(p.accepts('deny'), isTrue);
    }
    h.c.dispose();
  });
  test('free clarification uses exact answer string body', () async {
    final h = Harness();
    h.data = run([
      {
        'kind': 'clarify',
        'prompt_id': 'q',
        'execution_generation': 3,
        'question': 'Where?',
        'choices': []
      }
    ]);
    await h.c.refresh();
    final p = h.c.snapshot!.controls.single;
    await h.c.decide(p, '');
    expect(h.posts, isEmpty);
    await h.c.decide(p, 'my answer');
    expect(h.actions.single, ControlAction.clarify);
    expect(h.posts.single,
        {'request_id': 'q', 'execution_generation': 3, 'answer': 'my answer'});
    h.c.dispose();
  });
  test(
      'refreshes before exact canonical decision and validates acknowledgement',
      () async {
    final scope =
        ControlScope(sourceId: 's', runId: 'r', authorityToken: Object());
    var reads = 0;
    final posts = <Map<String, Object?>>[];
    final c = AgentControlsController(ControlBoundary(
      scope: scope,
      isCurrentAuthority: (_) => true,
      supportsAction: (_) => true,
      refresh: () async {
        reads++;
        return PendingControlsSnapshot.fromJson(scope, run([approval()]));
      },
      postDecision: (action, body) async {
        expect(action, ControlAction.approval);
        posts.add(body);
        return const ControlPostResult(
            200, {'run_id': 'r', 'status': 'resolved', 'prompt_id': 'p'});
      },
    ));
    await c.refresh();
    final prompt = c.snapshot!.controls.single;
    await c.decide(prompt, 'once');
    expect(reads, 3);
    expect(posts.single,
        {'request_id': 'p', 'execution_generation': 3, 'choice': 'once'});
    expect(c.message, contains('not completion'));
    c.dispose();
  });
}

class Harness {
  final scope =
      ControlScope(sourceId: 's', runId: 'r', authorityToken: Object());
  ControlScope? returnScope;
  bool current = true;
  bool supported = true;
  int reads = 0;
  Completer<void>? gate;
  Map<String, Object?> data = run([approval()]);
  final posts = <Map<String, Object?>>[];
  final actions = <ControlAction>[];
  ControlRefreshReason? reason;
  ControlPostResult result = const ControlPostResult(
      200, {'run_id': 'r', 'prompt_id': 'p', 'status': 'resolved'});
  late final c = AgentControlsController(ControlBoundary(
    scope: scope,
    isCurrentAuthority: (_) => current,
    supportsAction: (_) => supported,
    refresh: () async {
      reads++;
      await gate?.future;
      return PendingControlsSnapshot.fromJson(returnScope ?? scope, data);
    },
    postDecision: (action, body) async {
      actions.add(action);
      posts.add(body);
      return result;
    },
    onReconciled: (_, why) => reason = why,
  ));
}
