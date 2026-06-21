import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/features/chat/data/chat_runtime_manager.dart';
import 'package:meow_agent/services/agent_runtime/goal_tree.dart';
import 'package:meow_agent/services/agent_runtime/task_ledger.dart';

void main() {
  TaskLedger ledgerWith(int subgoalCount) => TaskLedger(
    id: 'ledger-1',
    agentId: 'agent-1',
    source: LedgerSource.chat,
    mainGoal: 'Complete the task',
    languageCode: 'en',
    originalUserMessage: 'Complete the task',
    goalTree: GoalTree(
      mainGoal: 'Complete the task',
      subgoals: [
        for (var i = 0; i < subgoalCount; i++)
          Subgoal(id: 'sg${i + 1}', label: 'Step ${i + 1}'),
      ],
    ),
  );

  group('task ledger confirmation boundary', () {
    test('single-step ledger is persisted while confirmation is waiting', () {
      expect(
        shouldPersistTaskLedgerSnapshot(
          ledgerWith(1),
          awaitingConfirmation: true,
        ),
        isTrue,
      );
    });

    test('multi-step ledger is still persisted at a terminal boundary', () {
      expect(
        shouldPersistTaskLedgerSnapshot(
          ledgerWith(2),
          awaitingConfirmation: false,
        ),
        isTrue,
      );
    });

    test('single-step non-gated boundary does not add ledger history', () {
      expect(
        shouldPersistTaskLedgerSnapshot(
          ledgerWith(1),
          awaitingConfirmation: false,
        ),
        isFalse,
      );
    });
  });
}
