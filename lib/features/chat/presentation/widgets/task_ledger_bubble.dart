import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../../app/theme.dart';
import '../../../../services/agent_runtime/goal_tree.dart';
import '../../../../services/agent_runtime/task_ledger.dart';
import 'meow_bubble.dart';

const taskLedgerSentinelPrefix = '[[TASK_LEDGER]]';

String taskLedgerToSentinel(TaskLedger ledger) =>
    '$taskLedgerSentinelPrefix${jsonEncode(ledger.toJson())}';

TaskLedger? taskLedgerFromSentinel(String content) {
  if (!content.startsWith(taskLedgerSentinelPrefix)) return null;
  final raw = content.substring(taskLedgerSentinelPrefix.length).trim();
  if (raw.isEmpty) return null;
  try {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return TaskLedger.fromJson(json);
  } catch (_) {
    return null;
  }
}

class TaskLedgerBubble extends StatelessWidget {
  const TaskLedgerBubble({
    super.key,
    required this.ledger,
    this.live = false,
    this.timestamp,
  });

  final TaskLedger ledger;
  final bool live;
  final DateTime? timestamp;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final goals = ledger.goalTree.subgoals;
    final done = goals.where((g) => g.status == SubgoalStatus.done).length;
    final total = goals.length;
    final title = ledger.mainGoal.trim().isEmpty
        ? 'Task progress'
        : ledger.mainGoal.trim();
    final maxWidth = MediaQuery.of(context).size.width * 0.78;

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: extras.card,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(4),
              bottomRight: Radius.circular(16),
            ),
            border: Border.all(color: extras.subtleBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    live
                        ? Icons.auto_awesome_rounded
                        : Icons.task_alt_rounded,
                    size: 18,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    total == 0 ? '0/0' : '$done/$total',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              if (live) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 4,
                    value: total == 0 ? null : done / total,
                    backgroundColor: cs.onSurface.withValues(alpha: 0.06),
                    valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              for (final goal in goals) _GoalRow(goal: goal),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  timestamp != null
                      ? formatBubbleTime(context, timestamp!)
                      : '',
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoalRow extends StatelessWidget {
  const _GoalRow({required this.goal});

  final Subgoal goal;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final status = goal.status;
    final terminal = goal.isTerminal;
    final failed = status == SubgoalStatus.failed;
    final skipped = status == SubgoalStatus.skipped;
    final active = status == SubgoalStatus.inProgress;
    final icon = failed
        ? Icons.close_rounded
        : skipped
            ? Icons.remove_rounded
            : terminal
                ? Icons.check_rounded
                : active
                    ? Icons.more_horiz_rounded
                    : Icons.radio_button_unchecked_rounded;
    final color = failed
        ? Colors.redAccent
        : skipped
            ? cs.onSurfaceVariant
            : terminal
                ? cs.primary
                : active
                    ? cs.primary
                    : cs.onSurfaceVariant.withValues(alpha: 0.5);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: color.withValues(alpha: terminal || active ? 0.16 : 0.08),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              goal.label,
              style: TextStyle(
                fontSize: 14,
                color: terminal ? cs.onSurfaceVariant : cs.onSurface,
                height: 1.35,
                decoration: terminal && !failed && !skipped
                    ? TextDecoration.lineThrough
                    : TextDecoration.none,
                decorationColor: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
