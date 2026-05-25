import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import 'workflow_database.dart';
import 'workflow_model.dart';

/// Repository for workflow CRUD and execution history.
class WorkflowRepository {
  final WorkflowDatabase _db = WorkflowDatabase();

  /// Max active workflows allowed.
  static const int maxWorkflows = 20;

  // ─── Workflow CRUD ──────────────────────────────────────────────────────────

  /// Create a new workflow. Returns false if max limit reached.
  Future<bool> create(WorkflowModel workflow) async {
    final db = await _db.database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM workflows WHERE enabled = 1'),
    ) ?? 0;
    if (count >= maxWorkflows) return false;

    await db.insert('workflows', _db.workflowToRow(workflow));
    return true;
  }

  /// Get all workflows, optionally filtered by agent.
  Future<List<WorkflowModel>> list({String? agentId}) async {
    final db = await _db.database;
    final rows = agentId != null
        ? await db.query('workflows',
            where: 'agent_id = ?',
            whereArgs: [agentId],
            orderBy: 'created_at DESC')
        : await db.query('workflows', orderBy: 'created_at DESC');
    return rows.map(_db.workflowFromRow).toList();
  }

  /// Get a single workflow by ID.
  Future<WorkflowModel?> read(String id) async {
    final db = await _db.database;
    final rows =
        await db.query('workflows', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _db.workflowFromRow(rows.first);
  }

  /// Update a workflow.
  Future<bool> update(WorkflowModel workflow) async {
    final db = await _db.database;
    final count = await db.update(
      'workflows',
      _db.workflowToRow(workflow),
      where: 'id = ?',
      whereArgs: [workflow.id],
    );
    return count > 0;
  }

  /// Delete a workflow.
  Future<bool> delete(String id) async {
    final db = await _db.database;
    final count =
        await db.delete('workflows', where: 'id = ?', whereArgs: [id]);
    return count > 0;
  }

  /// Toggle enabled state.
  Future<bool> toggle(String id, bool enabled) async {
    final db = await _db.database;
    final count = await db.update(
      'workflows',
      {'enabled': enabled ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
    return count > 0;
  }

  /// Get all enabled workflows (for scheduler).
  Future<List<WorkflowModel>> listEnabled() async {
    final db = await _db.database;
    final rows = await db.query('workflows', where: 'enabled = 1');
    return rows.map(_db.workflowFromRow).toList();
  }

  /// Update last run info after execution.
  Future<void> updateLastRun(
    String id, {
    required DateTime lastRun,
    required String lastResult,
    int retryCount = 0,
  }) async {
    final db = await _db.database;
    await db.update(
      'workflows',
      {
        'last_run': lastRun.toIso8601String(),
        'last_result': lastResult,
        'retry_count': retryCount,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ─── Execution History ─────────────────────────────────────────────────────

  /// Log an execution result.
  Future<void> logExecution(WorkflowExecution execution) async {
    final db = await _db.database;
    await db.insert('execution_history', {
      'workflow_id': execution.workflowId,
      'agent_id': execution.agentId,
      'workflow_title': execution.workflowTitle,
      'status': execution.status,
      'result': execution.result,
      'executed_at': execution.executedAt.toIso8601String(),
      'duration_ms': execution.durationMs,
    });
  }

  /// Get execution history, optionally filtered by agent.
  Future<List<WorkflowExecution>> getHistory({
    String? agentId,
    int limit = 50,
  }) async {
    final db = await _db.database;
    final rows = agentId != null
        ? await db.query(
            'execution_history',
            where: 'agent_id = ?',
            whereArgs: [agentId],
            orderBy: 'executed_at DESC',
            limit: limit,
          )
        : await db.query(
            'execution_history',
            orderBy: 'executed_at DESC',
            limit: limit,
          );
    return rows.map(_db.executionFromRow).toList();
  }

  /// Clear history for a specific workflow.
  Future<void> clearHistory(String workflowId) async {
    final db = await _db.database;
    await db.delete('execution_history',
        where: 'workflow_id = ?', whereArgs: [workflowId]);
  }
}

final workflowRepositoryProvider = Provider((_) => WorkflowRepository());
