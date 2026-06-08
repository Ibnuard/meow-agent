import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:meow_agent/services/agent_runtime/goal_tree.dart';
import 'package:meow_agent/services/agent_runtime/task_ledger.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  TaskLedger sampleLedger({
    String id = 'l1',
    String agentId = 'a1',
    LedgerSource source = LedgerSource.chat,
    String mainGoal = 'multi step',
    int subgoalCount = 3,
  }) {
    final tree = GoalTree(
      mainGoal: mainGoal,
      subgoals: [
        for (var i = 1; i <= subgoalCount; i++)
          Subgoal(id: 'sg$i', label: 'subgoal $i'),
      ],
    );
    return TaskLedger(
      id: id,
      agentId: agentId,
      source: source,
      mainGoal: mainGoal,
      languageCode: 'id',
      originalUserMessage: 'do many things',
      goalTree: tree,
    );
  }

  group('TaskLedger model', () {
    test('isActive / isTerminal reflect status', () {
      final l = sampleLedger();
      expect(l.isActive, true);
      expect(l.isTerminal, false);

      l.status = LedgerStatus.completed;
      expect(l.isActive, false);
      expect(l.isTerminal, true);
    });

    test('json round-trip preserves all fields', () {
      final original = sampleLedger();
      original.previousResults = [
        {'step': 1, 'tool': 'system.agents.delete', 'result': null},
      ];
      original.targetGraph = {
        'targets': [
          {
            'key': 'sg1',
            'entity_type': 'agent',
            'entity_label': 'Agent A',
            'operation': 'delete',
            'status': 'eligible',
          },
        ],
      };
      original.currentStep = 2;

      final restored = TaskLedger.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.agentId, original.agentId);
      expect(restored.source, original.source);
      expect(restored.mainGoal, original.mainGoal);
      expect(restored.languageCode, original.languageCode);
      expect(restored.goalTree.subgoals.length, 3);
      expect(restored.previousResults.length, 1);
      expect((restored.targetGraph['targets'] as List).length, 1);
      expect(restored.currentStep, 2);
    });

    test('describeForUser shows progress', () {
      final l = sampleLedger();
      l.goalTree.subgoals.first.status = SubgoalStatus.done;
      final desc = l.describeForUser();
      expect(desc, contains('multi step'));
      expect(desc, contains('1/3'));
    });

    test('LedgerStatusX.fromLabel handles unknown gracefully', () {
      expect(LedgerStatusX.fromLabel(null), LedgerStatus.active);
      expect(LedgerStatusX.fromLabel('garbage'), LedgerStatus.active);
      expect(LedgerStatusX.fromLabel('completed'), LedgerStatus.completed);
      expect(LedgerStatusX.fromLabel('aborted'), LedgerStatus.aborted);
      expect(LedgerStatusX.fromLabel('failed'), LedgerStatus.failed);
    });

    test('LedgerSourceX.fromLabel defaults to chat', () {
      expect(LedgerSourceX.fromLabel(null), LedgerSource.chat);
      expect(LedgerSourceX.fromLabel('chat'), LedgerSource.chat);
      expect(LedgerSourceX.fromLabel('workflow'), LedgerSource.workflow);
      expect(LedgerSourceX.fromLabel('unknown'), LedgerSource.chat);
    });
  });

  group('TaskLedgerDatabase persistence', () {
    late TaskLedgerDatabase db;

    setUp(() async {
      db = TaskLedgerDatabase(overrideDbPath: inMemoryDatabasePath);
    });

    tearDown(() async {
      await db.close();
    });

    test('upsert + findById round-trip', () async {
      final l = sampleLedger();
      await db.upsert(l);
      final found = await db.findById(l.id);
      expect(found, isNotNull);
      expect(found!.id, l.id);
      expect(found.goalTree.subgoals.length, 3);
    });

    test('findActive returns only active ledger for scope', () async {
      final chat = sampleLedger(id: 'l_chat', source: LedgerSource.chat);
      final wf = sampleLedger(id: 'l_wf', source: LedgerSource.workflow);
      await db.upsert(chat);
      await db.upsert(wf);

      final activeChat =
          await db.findActive(agentId: 'a1', source: LedgerSource.chat);
      expect(activeChat?.id, 'l_chat');

      final activeWf =
          await db.findActive(agentId: 'a1', source: LedgerSource.workflow);
      expect(activeWf?.id, 'l_wf');
    });

    test('findActive ignores terminal ledgers', () async {
      final l = sampleLedger();
      await db.upsert(l);
      await db.archive(l.id, LedgerStatus.completed);

      final active = await db.findActive(
        agentId: 'a1',
        source: LedgerSource.chat,
      );
      expect(active, isNull);
    });

    test('archive flips status and sets completed_at', () async {
      final l = sampleLedger();
      await db.upsert(l);
      await db.archive(l.id, LedgerStatus.completed);

      final found = await db.findById(l.id);
      expect(found!.status, LedgerStatus.completed);
      expect(found.completedAt, isNotNull);
    });

    test('archive with active throws', () async {
      final l = sampleLedger();
      await db.upsert(l);
      expect(
        () => db.archive(l.id, LedgerStatus.active),
        throwsArgumentError,
      );
    });

    test('delete removes the row', () async {
      final l = sampleLedger();
      await db.upsert(l);
      await db.delete(l.id);
      expect(await db.findById(l.id), isNull);
    });

    test('listActive returns all active ledgers for an agent', () async {
      await db.upsert(
        sampleLedger(id: 'l1', source: LedgerSource.chat),
      );
      await db.upsert(
        sampleLedger(id: 'l2', source: LedgerSource.workflow),
      );
      // Archive a third so it's filtered out.
      final terminal = sampleLedger(id: 'l3', source: LedgerSource.chat);
      await db.upsert(terminal);
      await db.archive('l3', LedgerStatus.completed);

      final list = await db.listActive(agentId: 'a1');
      expect(list.length, 2);
      expect(list.map((l) => l.id).toSet(), {'l1', 'l2'});
    });

    test('upsert replaces on same id (resume scenario)', () async {
      final l = sampleLedger();
      await db.upsert(l);

      l.currentStep = 5;
      l.previousResults = [
        {'step': 1, 'tool': 'foo', 'result': null}
      ];
      await db.upsert(l);

      final found = await db.findById(l.id);
      expect(found!.currentStep, 5);
      expect(found.previousResults.length, 1);
    });

    test('deleteAllForAgent wipes every status, scoped to agent', () async {
      // a1: one active (chat), one archived (workflow) — both must go.
      await db.upsert(sampleLedger(id: 'a1_active', agentId: 'a1'));
      await db.upsert(
        sampleLedger(id: 'a1_done', agentId: 'a1', source: LedgerSource.workflow),
      );
      await db.archive('a1_done', LedgerStatus.completed);
      // a2: must remain — different agent.
      await db.upsert(sampleLedger(id: 'a2_active', agentId: 'a2'));

      final removed = await db.deleteAllForAgent('a1');
      expect(removed, 2);

      expect(await db.findById('a1_active'), isNull);
      expect(await db.findById('a1_done'), isNull);
      expect(await db.findById('a2_active'), isNotNull);
    });
  });
}
