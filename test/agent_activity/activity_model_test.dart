import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/agent_activity/activity_model.dart';

ActivityBinding bind(ActivityModel m, {String revision = '1'}) => m.bind(
    connectionId: 'a',
    revision: revision,
    connectionName: 'Home',
    localChatId: 'chat',
    runId: 'run',
    title: 'Title');
Map<String, Object?> start(int seq, {String id = 'child'}) =>
    {'event': 'subagent.start', 'run_id': 'run', 'seq': seq, 'subagent_id': id};

void main() {
  test('revoking one local parent preserves same-server activity', () {
    final m = ActivityModel(redact: (s) => s);
    final a = bind(m);
    final b = m.bind(
        connectionId: 'a',
        revision: '1',
        connectionName: 'Home',
        localChatId: 'other',
        runId: 'other',
        title: 'Other');
    m.removeBinding(a);
    expect(m.canNavigate(a), false);
    expect(m.canNavigate(b), true);
    m.dispose();
  });
  test('retention prefers terminal parents and signals active overflow', () {
    final m = ActivityModel(redact: (s) => s, maxParents: 2, maxChildren: 1);
    final a = bind(m);
    final b = m.bind(
        connectionId: 'b',
        revision: '1',
        connectionName: '',
        localChatId: 'b',
        runId: 'b',
        title: '');
    m.updateStatus(b, ActivityStatus.completed);
    m.bind(
        connectionId: 'c',
        revision: '1',
        connectionName: '',
        localChatId: 'c',
        runId: 'c',
        title: '');
    expect(m.canNavigate(a), isTrue);
    expect(m.canNavigate(b), isFalse);
    m.bind(
        connectionId: 'd',
        revision: '1',
        connectionName: '',
        localChatId: 'd',
        runId: 'd',
        title: '');
    expect(m.parentsOverflow, isTrue);
    expect(m.canNavigate(a), isTrue);
    m.event(a, start(1));
    m.event(a, start(2, id: 'extra'));
    expect(m.parents.first.childrenOverflow, isTrue);
    m.dispose();
  });
  test('oversized text fails closed across redaction boundary', () {
    final secret = 's' * 2100;
    final m = ActivityModel(redact: (s) => s.replaceAll(secret, '[hidden]'));
    final b = bind(m);
    m.event(b, {...start(1), 'goal': secret});
    expect(m.parents.single.children.single.goal, 'Child task');
    m.dispose();
  });
  test('stopping interrupted and answer needed are distinct', () {
    expect(ActivityStatus.interrupted.terminal, isTrue);
    expect(ActivityStatus.stopping.terminal, isFalse);
    expect(ActivityStatus.answerNeeded.needsAttention, isTrue);
  });
  test('terminal children are evicted before later active children', () {
    final m = ActivityModel(redact: (s) => s, maxChildren: 1);
    final b = bind(m);
    m.updateStatus(b, ActivityStatus.running);
    m.event(
        b, {...start(1), 'event': 'subagent.complete', 'status': 'completed'});
    m.event(b, start(2, id: 'new'));
    expect(m.parents.single.children.single.subagentId, 'new');
    m.dispose();
  });
  test(
      'replays, sequence gaps, disconnect and terminal parents are conservative',
      () {
    final m = ActivityModel(redact: (s) => s);
    final b = bind(m);
    m.updateStatus(b, ActivityStatus.running);
    m.event(b, start(1), cursor: '1');
    m.event(b, start(1, id: 'replay'), cursor: '1');
    expect(m.parents.single.children.length, 1);
    m.event(b, start(3, id: 'gap'));
    expect(m.parents.single.status, ActivityStatus.unknown);
    expect(
        m.parents.single.children
            .every((c) => c.status == ActivityStatus.unknown),
        isTrue);
    m.event(b, start(4, id: 'after-gap'));
    expect(m.parents.single.children.last.status, ActivityStatus.unknown);
    m.updateStatus(b, ActivityStatus.running);
    m.event(b, start(5, id: 'fresh'));
    expect(m.parents.single.children.last.status, ActivityStatus.running);
    m.disconnected(b);
    expect(m.parents.single.children.last.status, ActivityStatus.unknown);
    m.updateStatus(b, ActivityStatus.completed);
    m.event(b, start(6, id: 'late'));
    m.updateStatus(b, ActivityStatus.running);
    expect(m.parents.single.status, ActivityStatus.completed);
    expect(m.parents.single.children.last.status, ActivityStatus.unknown);
    m.event(b, {
      'event': 'subagent.complete',
      'run_id': 'run',
      'seq': 7,
      'subagent_id': 'late',
      'status': 'completed'
    });
    m.event(b, start(8, id: 'late'));
    expect(m.parents.single.children.last.status, ActivityStatus.completed);
    m.dispose();
  });
  test(
      'malformed sequence cannot create children; private payload is never copied',
      () {
    final m = ActivityModel(redact: (s) => s.replaceAll('SECRET', '[hidden]'));
    final b = bind(m);
    m.updateStatus(b, ActivityStatus.running);
    m.event(b, {
      'event': 'subagent.start',
      'run_id': 'run',
      'seq': 'wrong',
      'subagent_id': 'invalid'
    });
    expect(m.parents.single.children, isEmpty);
    m.event(b, {
      'event': 'subagent.start',
      'run_id': 'other',
      'seq': 1,
      'subagent_id': 'wrong-run'
    });
    m.event(b, {
      'event': 'subagent.start',
      'run_id': 'run',
      'seq': 1,
      'subagent_id': {},
      'task_index': 0,
      'delegation_id': 'batch'
    });
    expect(m.parents.single.children, isEmpty);
    m.event(b, {
      'event': 'subagent.start',
      'run_id': 'run',
      'seq': 2,
      'subagent_id': 'ok',
      'goal': 'SECRET\ninspect',
      'summary': {'private': 'SECRET'},
      'arguments': {'secret': 'PRIVATE'},
      'output_tail': 'PRIVATE',
      'reasoning': 'PRIVATE'
    });
    final c = m.parents.single.children.single;
    expect(c.goal, '[hidden] inspect');
    expect(c.summary, isEmpty);
    m.dispose();
  });
  test('bounded memory and connection revision revoke identity and navigation',
      () {
    final m = ActivityModel(redact: (s) => s, maxParents: 2, maxChildren: 2);
    final old = bind(m);
    m.event(old, start(1));
    m.event(old, start(2, id: 'two'));
    m.event(old, start(3, id: 'three'));
    expect(m.parents.single.children.length, 2);
    final current = bind(m, revision: '2');
    expect(m.canNavigate(old), isFalse);
    m.event(old, start(4));
    expect(m.parents.single.children, isEmpty);
    expect(m.canNavigate(current), isTrue);
    m.dispose();
    m.event(current, start(5));
    m.updateStatus(current, ActivityStatus.running);
    expect(m.parents, isEmpty);
    expect(m.canNavigate(current), isFalse);
  });
  test('trusted binding separates servers; batch is not a child', () {
    final model =
        ActivityModel(redact: (s) => s.replaceAll('SECRET', '[hidden]'));
    final a = model.bind(
        connectionId: 'a',
        revision: '1',
        connectionName: 'Home',
        localChatId: 'chat',
        runId: 'run',
        title: 'Original');
    final b = model.bind(
        connectionId: 'b',
        revision: '1',
        connectionName: 'Work',
        localChatId: 'chat',
        runId: 'run',
        title: 'Other');
    model.updateStatus(a, ActivityStatus.running);
    model.updateStatus(b, ActivityStatus.waitingApproval);
    model.event(a, {
      'event': 'subagent.start',
      'run_id': 'run',
      'seq': 1,
      'task_count': 3
    });
    expect(model.parents.first.children, isEmpty);
    model.event(a, {
      'event': 'subagent.start',
      'run_id': 'run',
      'seq': 2,
      'task_count': 3,
      'subagent_id': 'same',
      'child_session_id': 'session',
      'delegation_id': 'batch',
      'goal': 'SECRET inspect',
      'output_tail': 'PRIVATE'
    });
    model.event(b, {
      'event': 'subagent.start',
      'run_id': 'run',
      'seq': 1,
      'subagent_id': 'same'
    });
    expect(model.parents.length, 2);
    final child = model.parents.first.children.single;
    expect(child.subagentId, 'same');
    expect(child.childSessionId, 'session');
    expect(child.delegationId, 'batch');
    expect(child.goal, '[hidden] inspect');
    expect(model.parents.first.batchTaskCount, 3);
    expect(model.canNavigate(a), isTrue);
    model.dispose();
  });
}
