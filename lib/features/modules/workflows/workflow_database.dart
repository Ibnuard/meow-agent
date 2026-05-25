import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'workflow_model.dart';

/// SQLite database for workflows and execution history.
class WorkflowDatabase {
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _init();
    return _db!;
  }

  Future<Database> _init() async {
    final dbDir = await getDatabasesPath();
    final path = '$dbDir/meow_workflows.db';
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE workflows (
            id TEXT PRIMARY KEY,
            agent_id TEXT NOT NULL,
            title TEXT NOT NULL,
            prompt TEXT NOT NULL,
            trigger_config TEXT NOT NULL,
            notif_config TEXT NOT NULL,
            send_to_chat INTEGER NOT NULL DEFAULT 0,
            enabled INTEGER NOT NULL DEFAULT 1,
            last_run TEXT,
            last_result TEXT,
            retry_count INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_workflows_agent ON workflows(agent_id)
        ''');
        await db.execute('''
          CREATE TABLE execution_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            workflow_id TEXT NOT NULL,
            agent_id TEXT NOT NULL,
            workflow_title TEXT NOT NULL,
            status TEXT NOT NULL,
            result TEXT NOT NULL,
            executed_at TEXT NOT NULL,
            duration_ms INTEGER
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_history_agent ON execution_history(agent_id)
        ''');
        await db.execute('''
          CREATE INDEX idx_history_workflow ON execution_history(workflow_id)
        ''');
      },
    );
  }

  /// Convert WorkflowModel to DB row.
  Map<String, dynamic> workflowToRow(WorkflowModel w) => {
        'id': w.id,
        'agent_id': w.agentId,
        'title': w.title,
        'prompt': w.prompt,
        'trigger_config': jsonEncode(w.trigger.toJson()),
        'notif_config': jsonEncode(w.notification.toJson()),
        'send_to_chat': w.sendToChat ? 1 : 0,
        'enabled': w.enabled ? 1 : 0,
        'last_run': w.lastRun?.toIso8601String(),
        'last_result': w.lastResult,
        'retry_count': w.retryCount,
        'created_at': w.createdAt.toIso8601String(),
      };

  /// Convert DB row to WorkflowModel.
  WorkflowModel workflowFromRow(Map<String, dynamic> row) => WorkflowModel(
        id: row['id'] as String,
        agentId: row['agent_id'] as String,
        title: row['title'] as String,
        prompt: row['prompt'] as String,
        trigger: TriggerConfig.fromJson(
          jsonDecode(row['trigger_config'] as String) as Map<String, dynamic>,
        ),
        notification: NotifConfig.fromJson(
          jsonDecode(row['notif_config'] as String) as Map<String, dynamic>,
        ),
        sendToChat: (row['send_to_chat'] as int) == 1,
        enabled: (row['enabled'] as int) == 1,
        lastRun: row['last_run'] != null
            ? DateTime.tryParse(row['last_run'] as String)
            : null,
        lastResult: row['last_result'] as String?,
        retryCount: row['retry_count'] as int? ?? 0,
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  /// Convert DB row to WorkflowExecution.
  WorkflowExecution executionFromRow(Map<String, dynamic> row) =>
      WorkflowExecution(
        id: row['id'] as int?,
        workflowId: row['workflow_id'] as String,
        agentId: row['agent_id'] as String,
        workflowTitle: row['workflow_title'] as String,
        status: row['status'] as String,
        result: row['result'] as String,
        executedAt: DateTime.parse(row['executed_at'] as String),
        durationMs: row['duration_ms'] as int?,
      );
}
