import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// Lifecycle of a whole workflow RUN (GitHub-Actions style).
///
/// - [running]: the run is in flight (at least one step pending/running)
/// - [success]: every non-skipped step succeeded
/// - [partial]: some steps were skipped (condition/skip-on-fail) but no hard stop
/// - [failed]: a step stopped the chain (hard fail, timeout, or sensitive block)
enum WorkflowRunStatus { running, success, failed, partial }

extension WorkflowRunStatusX on WorkflowRunStatus {
  String get label => switch (this) {
    WorkflowRunStatus.running => 'running',
    WorkflowRunStatus.success => 'success',
    WorkflowRunStatus.failed => 'failed',
    WorkflowRunStatus.partial => 'partial',
  };

  static WorkflowRunStatus fromLabel(String? raw) {
    switch (raw) {
      case 'success':
        return WorkflowRunStatus.success;
      case 'partial':
        return WorkflowRunStatus.partial;
      case 'failed':
        return WorkflowRunStatus.failed;
      case 'running':
      default:
        return WorkflowRunStatus.running;
    }
  }
}

/// Status of one step inside a run.
///
/// `blocked` is distinct from `failed`: it means the step needed a sensitive
/// action while the workflow's "Allow sensitive actions" toggle was off.
enum WorkflowStepStatus { pending, running, success, failed, skipped, blocked }

extension WorkflowStepStatusX on WorkflowStepStatus {
  String get label => switch (this) {
    WorkflowStepStatus.pending => 'pending',
    WorkflowStepStatus.running => 'running',
    WorkflowStepStatus.success => 'success',
    WorkflowStepStatus.failed => 'failed',
    WorkflowStepStatus.skipped => 'skipped',
    WorkflowStepStatus.blocked => 'blocked',
  };

  static WorkflowStepStatus fromLabel(String? raw) {
    switch (raw) {
      case 'running':
        return WorkflowStepStatus.running;
      case 'success':
        return WorkflowStepStatus.success;
      case 'failed':
        return WorkflowStepStatus.failed;
      case 'skipped':
        return WorkflowStepStatus.skipped;
      case 'blocked':
        return WorkflowStepStatus.blocked;
      case 'pending':
      default:
        return WorkflowStepStatus.pending;
    }
  }
}

/// One step entry inside a [WorkflowRunLedger].
///
/// Each step is a single `engine.run()` (= one main goal, possibly with many
/// internal subgoals). Steps in a run may target DIFFERENT agents — this is
/// the whole reason the run ledger spans agents instead of being keyed by one.
class WorkflowStepEntry {
  WorkflowStepEntry({
    required this.index,
    required this.stepId,
    required this.agentId,
    required this.agentName,
    required this.mainGoal,
    this.status = WorkflowStepStatus.pending,
    this.result = '',
    this.failureReason,
    this.durationMs,
  });

  final int index;
  final String stepId;
  final String agentId;
  final String agentName;

  /// The step's resolved instruction (truncated for storage).
  final String mainGoal;

  WorkflowStepStatus status;
  String result;

  /// Human-readable reason when [status] is failed/blocked.
  String? failureReason;
  int? durationMs;

  Map<String, dynamic> toJson() => {
    'index': index,
    'step_id': stepId,
    'agent_id': agentId,
    'agent_name': agentName,
    'main_goal': mainGoal,
    'status': status.label,
    'result': result,
    if (failureReason != null) 'failure_reason': failureReason,
    if (durationMs != null) 'duration_ms': durationMs,
  };

  factory WorkflowStepEntry.fromJson(Map<String, dynamic> json) =>
      WorkflowStepEntry(
        index: (json['index'] as num?)?.toInt() ?? 0,
        stepId: json['step_id'] as String? ?? '',
        agentId: json['agent_id'] as String? ?? '',
        agentName: json['agent_name'] as String? ?? '',
        mainGoal: json['main_goal'] as String? ?? '',
        status: WorkflowStepStatusX.fromLabel(json['status'] as String?),
        result: json['result'] as String? ?? '',
        failureReason: json['failure_reason'] as String?,
        durationMs: (json['duration_ms'] as num?)?.toInt(),
      );
}

/// A single workflow RUN spanning all of its steps and agents.
///
/// Owned by the [WorkflowRunner]. Persisted to its own SQLite file so a future
/// "currently running" view (like GitHub Actions) can read live state. There
/// is NO resume: a run that dies mid-flight is swept to `failed` on next DB
/// open, and the user re-runs the whole workflow.
class WorkflowRunLedger {
  WorkflowRunLedger({
    required this.runId,
    required this.workflowId,
    required this.workflowTitle,
    required this.agentId,
    required this.steps,
    this.status = WorkflowRunStatus.running,
    this.currentStepIndex = 0,
    DateTime? startedAt,
    this.finishedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  final String runId;
  final String workflowId;
  final String workflowTitle;

  /// The workflow's primary/owner agent. Individual steps may run as other
  /// agents — see [WorkflowStepEntry.agentId].
  final String agentId;

  final List<WorkflowStepEntry> steps;
  WorkflowRunStatus status;
  int currentStepIndex;
  final DateTime startedAt;
  DateTime? finishedAt;

  bool get isRunning => status == WorkflowRunStatus.running;

  WorkflowStepEntry? stepAt(int index) {
    for (final s in steps) {
      if (s.index == index) return s;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'run_id': runId,
    'workflow_id': workflowId,
    'workflow_title': workflowTitle,
    'agent_id': agentId,
    'status': status.label,
    'current_step_index': currentStepIndex,
    'started_at': startedAt.toIso8601String(),
    'finished_at': finishedAt?.toIso8601String(),
    'steps': steps.map((s) => s.toJson()).toList(),
  };

  factory WorkflowRunLedger.fromJson(Map<String, dynamic> json) =>
      WorkflowRunLedger(
        runId: json['run_id'] as String,
        workflowId: json['workflow_id'] as String? ?? '',
        workflowTitle: json['workflow_title'] as String? ?? '',
        agentId: json['agent_id'] as String? ?? '',
        status: WorkflowRunStatusX.fromLabel(json['status'] as String?),
        currentStepIndex: (json['current_step_index'] as num?)?.toInt() ?? 0,
        startedAt:
            DateTime.tryParse(json['started_at'] as String? ?? '') ??
            DateTime.now(),
        finishedAt: json['finished_at'] != null
            ? DateTime.tryParse(json['finished_at'] as String)
            : null,
        steps:
            (json['steps'] as List?)
                ?.whereType<Map>()
                .map(
                  (m) => WorkflowStepEntry.fromJson(m.cast<String, dynamic>()),
                )
                .toList() ??
            <WorkflowStepEntry>[],
      );

  /// Build a run ledger from an ordered list of (stepId, agentId, agentName,
  /// instruction) tuples. Used by the runner at the start of a run.
  factory WorkflowRunLedger.start({
    required String workflowId,
    required String workflowTitle,
    required String agentId,
    required List<WorkflowStepEntry> steps,
  }) {
    final runId =
        'wfr_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '_${workflowId.hashCode.toUnsigned(16).toRadixString(16)}';
    return WorkflowRunLedger(
      runId: runId,
      workflowId: workflowId,
      workflowTitle: workflowTitle,
      agentId: agentId,
      steps: steps,
    );
  }
}

/// SQLite-backed store for [WorkflowRunLedger].
///
/// Own database file (`meow_workflow_runs.db`) per project convention of one
/// SQLite file per concern. On open, sweeps any orphaned `running` rows to
/// `failed` — there is no resume, so a row left running means the process died
/// mid-run.
class WorkflowRunDatabase {
  WorkflowRunDatabase({String? overrideDbPath})
    : _overrideDbPath = overrideDbPath;

  final String? _overrideDbPath;
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _init();
    return _db!;
  }

  Future<Database> _init() async {
    final path =
        _overrideDbPath ?? '${await getDatabasesPath()}/meow_workflow_runs.db';
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE workflow_runs (
            run_id TEXT PRIMARY KEY,
            workflow_id TEXT NOT NULL,
            workflow_title TEXT NOT NULL,
            agent_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'running',
            current_step_index INTEGER NOT NULL DEFAULT 0,
            payload_json TEXT NOT NULL,
            started_at TEXT NOT NULL,
            finished_at TEXT
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_runs_status ON workflow_runs(status, started_at)
        ''');
        await db.execute('''
          CREATE INDEX idx_runs_workflow ON workflow_runs(workflow_id)
        ''');
      },
      onOpen: (db) async {
        // Stale-run sweep: any row still `running` belongs to a dead process
        // (no resume exists). Mark it failed so the live view never shows a
        // zombie run.
        await _sweep(db);
      },
    );
  }

  /// Flip any `running` rows to `failed`. Runs automatically on DB open; also
  /// callable explicitly. Returns the number of rows swept.
  Future<int> sweepStaleRuns() async => _sweep(await database);

  Future<int> _sweep(Database db) async {
    final rows = await db.query(
      'workflow_runs',
      where: 'status = ?',
      whereArgs: [WorkflowRunStatus.running.label],
    );
    if (rows.isEmpty) return 0;
    // Rewrite the FULL payload, not just the status column. _fromRow
    // reconstructs everything from payload_json, so patching only the column
    // would leave the JSON (and every read) saying "running".
    for (final row in rows) {
      final run = _fromRow(row);
      run.status = WorkflowRunStatus.failed;
      run.finishedAt = DateTime.now();
      await db.insert(
        'workflow_runs',
        _toRow(run),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    return rows.length;
  }

  /// Insert or replace a run ledger (full payload).
  Future<void> upsert(WorkflowRunLedger run) async {
    final db = await database;
    await db.insert(
      'workflow_runs',
      _toRow(run),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// All runs currently `running` (live view). Should be 0 or 1 in practice
  /// since the runner executes one workflow at a time.
  Future<List<WorkflowRunLedger>> listRunning() async {
    final db = await database;
    final rows = await db.query(
      'workflow_runs',
      where: 'status = ?',
      whereArgs: [WorkflowRunStatus.running.label],
      orderBy: 'started_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Recent runs for history/diagnostics.
  Future<List<WorkflowRunLedger>> listRecent({int limit = 50}) async {
    final db = await database;
    final rows = await db.query(
      'workflow_runs',
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  Future<WorkflowRunLedger?> findById(String runId) async {
    final db = await database;
    final rows = await db.query(
      'workflow_runs',
      where: 'run_id = ?',
      whereArgs: [runId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Prune old terminal runs, keeping the most recent [keep].
  Future<void> prune({int keep = 200}) async {
    final db = await database;
    await db.rawDelete(
      '''
      DELETE FROM workflow_runs
      WHERE status != ?
        AND run_id NOT IN (
          SELECT run_id FROM workflow_runs
          ORDER BY started_at DESC LIMIT ?
        )
      ''',
      [WorkflowRunStatus.running.label, keep],
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Map<String, dynamic> _toRow(WorkflowRunLedger r) => {
    'run_id': r.runId,
    'workflow_id': r.workflowId,
    'workflow_title': r.workflowTitle,
    'agent_id': r.agentId,
    'status': r.status.label,
    'current_step_index': r.currentStepIndex,
    'payload_json': jsonEncode(r.toJson()),
    'started_at': r.startedAt.toIso8601String(),
    'finished_at': r.finishedAt?.toIso8601String(),
  };

  WorkflowRunLedger _fromRow(Map<String, dynamic> row) {
    final payload =
        jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
    return WorkflowRunLedger.fromJson(payload);
  }
}
