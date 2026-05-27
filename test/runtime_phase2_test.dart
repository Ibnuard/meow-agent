import 'package:flutter_test/flutter_test.dart';

import 'package:meow_agent/services/agent_runtime/goal_tree.dart';

void main() {
  group('Subgoal', () {
    test('default state is pending and not terminal', () {
      final s = Subgoal(id: 'sg1', label: 'create agent Coder');
      expect(s.status, SubgoalStatus.pending);
      expect(s.isTerminal, false);
      expect(s.isReady, true);
    });

    test('isReady false while missingSlots non-empty', () {
      final s = Subgoal(
        id: 'sg1',
        label: 'create agent',
        missingSlots: const ['persona'],
      );
      expect(s.isReady, false);
    });

    test('terminal once status is done/failed/skipped', () {
      for (final st in [
        SubgoalStatus.done,
        SubgoalStatus.failed,
        SubgoalStatus.skipped
      ]) {
        final s = Subgoal(id: 'x', label: 'x', status: st);
        expect(s.isTerminal, true,
            reason: 'expected terminal for status=${st.label}');
      }
    });

    test('JSON round-trip preserves all fields', () {
      final s = Subgoal(
        id: 'sg1',
        label: 'create agent Coder',
        requiredSlots: const {'name': 'Coder', 'persona': 'helpful'},
        missingSlots: const ['persona'],
        status: SubgoalStatus.inProgress,
        resultRef: 'tool_result_42',
        notes: 'agent_id=ag_42',
      );
      final json = s.toJson();
      final restored = Subgoal.fromJson(json);
      expect(restored.id, s.id);
      expect(restored.label, s.label);
      expect(restored.requiredSlots, s.requiredSlots);
      expect(restored.missingSlots, s.missingSlots);
      expect(restored.status, s.status);
      expect(restored.resultRef, s.resultRef);
      expect(restored.notes, s.notes);
    });

    test('SubgoalStatusX.fromLabel parses common variants', () {
      expect(SubgoalStatusX.fromLabel('done'), SubgoalStatus.done);
      expect(SubgoalStatusX.fromLabel('completed'), SubgoalStatus.done);
      expect(SubgoalStatusX.fromLabel('in_progress'), SubgoalStatus.inProgress);
      expect(SubgoalStatusX.fromLabel('inProgress'), SubgoalStatus.inProgress);
      expect(SubgoalStatusX.fromLabel('failed'), SubgoalStatus.failed);
      expect(SubgoalStatusX.fromLabel('skipped'), SubgoalStatus.skipped);
      expect(SubgoalStatusX.fromLabel(null), SubgoalStatus.pending);
      expect(SubgoalStatusX.fromLabel('garbage'), SubgoalStatus.pending);
    });
  });

  group('GoalTree — completion semantics', () {
    GoalTree tree() => GoalTree(
          mainGoal: 'create 3 agents',
          subgoals: [
            Subgoal(id: 'sg1', label: 'agent Coder'),
            Subgoal(id: 'sg2', label: 'agent Writer'),
            Subgoal(id: 'sg3', label: 'agent Researcher'),
          ],
        );

    test('isComplete false until every subgoal done', () {
      final t = tree();
      expect(t.isComplete, false);
      t.findById('sg1')!.status = SubgoalStatus.done;
      expect(t.isComplete, false);
      t.findById('sg2')!.status = SubgoalStatus.done;
      expect(t.isComplete, false);
      t.findById('sg3')!.status = SubgoalStatus.done;
      expect(t.isComplete, true);
    });

    test('failed subgoal reflected in hasFailed', () {
      final t = tree();
      t.findById('sg2')!.status = SubgoalStatus.failed;
      expect(t.hasFailed, true);
      // Should never report complete when any subgoal failed.
      t.findById('sg1')!.status = SubgoalStatus.done;
      t.findById('sg3')!.status = SubgoalStatus.done;
      expect(t.isComplete, false);
    });

    test('nextActionable picks pending in order, prefers in_progress', () {
      final t = tree();
      expect(t.nextActionable?.id, 'sg1');
      t.findById('sg1')!.status = SubgoalStatus.done;
      expect(t.nextActionable?.id, 'sg2');
      // Mark sg3 in_progress; should jump there over still-pending sg2.
      t.findById('sg3')!.status = SubgoalStatus.inProgress;
      expect(t.nextActionable?.id, 'sg3');
    });

    test('nextActionable null when all subgoals terminal', () {
      final t = tree();
      for (final s in t.subgoals) {
        s.status = SubgoalStatus.done;
      }
      expect(t.nextActionable, isNull);
    });

    test('applyStatusUpdate returns false for unknown id (no softlock)', () {
      final t = tree();
      final ok = t.applyStatusUpdate(
        subgoalId: 'sg_does_not_exist',
        status: SubgoalStatus.done,
      );
      expect(ok, false);
      // Tree state unchanged.
      expect(t.subgoals.every((s) => s.status == SubgoalStatus.pending), true);
    });

    test('applyStatusUpdate writes resultRef and notes', () {
      final t = tree();
      final ok = t.applyStatusUpdate(
        subgoalId: 'sg2',
        status: SubgoalStatus.done,
        resultRef: 'agent_id=ag_42',
        notes: 'persona derived from request',
      );
      expect(ok, true);
      final updated = t.findById('sg2')!;
      expect(updated.status, SubgoalStatus.done);
      expect(updated.resultRef, 'agent_id=ag_42');
      expect(updated.notes, 'persona derived from request');
    });
  });

  group('GoalTree — JSON round-trip', () {
    test('round-trips with completion criteria', () {
      final t = GoalTree(
        mainGoal: 'create 2 agents',
        completionCriteria: const ['2 agents present in registry'],
        subgoals: [
          Subgoal(id: 'sg1', label: 'agent A'),
          Subgoal(id: 'sg2', label: 'agent B', status: SubgoalStatus.done),
        ],
      );
      final restored = GoalTree.fromJson(t.toJson());
      expect(restored.mainGoal, t.mainGoal);
      expect(restored.completionCriteria, t.completionCriteria);
      expect(restored.subgoals.length, 2);
      expect(restored.subgoals[1].status, SubgoalStatus.done);
    });

    test('toCompactString lists each subgoal with status', () {
      final t = GoalTree(
        mainGoal: 'm',
        subgoals: [
          Subgoal(id: 'sg1', label: 'first'),
          Subgoal(
            id: 'sg2',
            label: 'second',
            missingSlots: const ['name'],
            status: SubgoalStatus.inProgress,
          ),
        ],
      );
      final s = t.toCompactString();
      expect(s, contains('sg1: first'));
      expect(s, contains('[in_progress]'));
      expect(s, contains('missing:name'));
    });

    test('singleSubgoal factory builds usable single-target tree', () {
      final t = GoalTree.singleSubgoal(
        mainGoal: 'open spotify',
        subgoalLabel: 'open spotify',
      );
      expect(t.subgoals.length, 1);
      expect(t.isComplete, false);
      t.subgoals.first.status = SubgoalStatus.done;
      expect(t.isComplete, true);
    });
  });

  group('StuckDetector', () {
    test('flags after threshold consecutive identical calls', () {
      final s = StuckDetector(threshold: 3);
      expect(s.observe(toolName: 'app.open', args: const {'pkg': 'x'}), false);
      expect(s.observe(toolName: 'app.open', args: const {'pkg': 'x'}), false);
      expect(s.observe(toolName: 'app.open', args: const {'pkg': 'x'}), true);
    });

    test('different args reset the counter', () {
      final s = StuckDetector(threshold: 3);
      s.observe(toolName: 'app.open', args: const {'pkg': 'x'});
      s.observe(toolName: 'app.open', args: const {'pkg': 'x'});
      // Different args now.
      expect(
        s.observe(toolName: 'app.open', args: const {'pkg': 'y'}),
        false,
      );
    });

    test('different tool resets the counter', () {
      final s = StuckDetector(threshold: 3);
      s.observe(toolName: 'app.open', args: const {});
      s.observe(toolName: 'app.open', args: const {});
      expect(s.observe(toolName: 'notes.create', args: const {}), false);
    });

    test('args order does not matter — canonicalized', () {
      final s = StuckDetector(threshold: 2);
      expect(
        s.observe(toolName: 't', args: const {'a': 1, 'b': 2}),
        false,
      );
      // Same logical args but different declaration order.
      expect(
        s.observe(toolName: 't', args: const {'b': 2, 'a': 1}),
        true,
      );
    });

    test('reset clears counter', () {
      final s = StuckDetector(threshold: 3);
      s.observe(toolName: 't', args: const {});
      s.observe(toolName: 't', args: const {});
      s.reset();
      expect(s.observe(toolName: 't', args: const {}), false);
    });
  });
}
