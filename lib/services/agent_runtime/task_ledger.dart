import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'goal_tree.dart';

/// Source of a [TaskLedger].
///
/// Multi-task scope is partitioned by source so a chat ledger never collides
/// with a concurrent workflow ledger on the same agent.
enum LedgerSource { chat, workflow }

extension LedgerSourceX on LedgerSource {
  String get label => switch (this) {
    LedgerSource.chat => 'chat',
    LedgerSource.workflow => 'workflow',
  };

  static LedgerSource fromLabel(String? raw) =>
      raw == 'workflow' ? LedgerSource.workflow : LedgerSource.chat;
}

/// Lifecycle state of a ledger.
///
/// - [active]: at least one subgoal still pending or in-progress
/// - [completed]: every subgoal terminal & all completion criteria met
/// - [aborted]: user explicitly cancelled or rejected mid-flow
/// - [failed]: unrecoverable runtime error or max retries exceeded
enum LedgerStatus { active, completed, aborted, failed }

extension LedgerStatusX on LedgerStatus {
  String get label => switch (this) {
    LedgerStatus.active => 'active',
    LedgerStatus.completed => 'completed',
    LedgerStatus.aborted => 'aborted',
    LedgerStatus.failed => 'failed',
  };

  static LedgerStatus fromLabel(String? raw) {
    switch (raw) {
      case 'completed':
        return LedgerStatus.completed;
      case 'aborted':
        return LedgerStatus.aborted;
      case 'failed':
        return LedgerStatus.failed;
      case 'active':
      default:
        return LedgerStatus.active;
    }
  }
}

/// Persistent multi-step task scope.
///
/// Created by the runtime when the reflector decides the user request needs
/// more than one subgoal. Survives app restarts so a user who confirms a
/// sensitive step then closes the app can resume on next launch.
///
/// **Ledger ≠ memory.** Agent identity and long-term memory live in the
/// `agent_soul` and `agent_memory` database tables, not in the ledger.
/// A ledger is the working memory of ONE multi-step task and is
/// soft-archived (status=completed/aborted/failed) once the task ends.
///
/// Scope is per (agent_id, source). At any time at most ONE active ledger
/// per scope. A new conflicting request triggers a clarify question:
/// revise the active ledger or replace it?
class TaskLedger {
  TaskLedger({
    required this.id,
    required this.agentId,
    required this.source,
    this.sourceRef,
    required this.mainGoal,
    required this.languageCode,
    required this.originalUserMessage,
    required this.goalTree,
    this.completionCriteria = const [],
    this.impacts = const [],
    this.targetGraph = const {},
    this.previousResults = const [],
    this.currentStep = 1,
    this.availableTools = const [],
    this.memorySnapshot = '',
    this.autoApproveSensitive = false,
    this.isWorkflowAutoExecute = false,
    this.plan,
    this.pendingToolName,
    this.pendingToolArgs,
    this.status = LedgerStatus.active,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.completedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String agentId;
  final LedgerSource source;

  /// Optional ref pointing back to the source. For [LedgerSource.workflow]
  /// this is the workflow id so we can join to execution history.
  final String? sourceRef;

  final String mainGoal;
  final String languageCode;
  final String originalUserMessage;

  /// The live goal tree. Mutated as subgoals advance; persist on every
  /// material change.
  GoalTree goalTree;
  final List<String> completionCriteria;
  final List<Map<String, dynamic>> impacts;
  Map<String, dynamic> targetGraph;

  /// Loop scratchpad. Append a record per executed step so the resumed loop
  /// has authoritative context after app restart.
  List<Map<String, dynamic>> previousResults;
  int currentStep;

  final List<String> availableTools;
  final String memorySnapshot;
  final bool autoApproveSensitive;
  final bool isWorkflowAutoExecute;

  /// Snapshot of the planner output. Needed by the loop on resume.
  Map<String, dynamic>? plan;

  /// Tool currently awaiting confirmation when the app was last killed.
  /// Used to rehydrate [PendingAction] on relaunch.
  String? pendingToolName;
  Map<String, dynamic>? pendingToolArgs;

  LedgerStatus status;
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? completedAt;

  bool get isActive => status == LedgerStatus.active;
  bool get isTerminal => status != LedgerStatus.active;

  Map<String, dynamic> toJson() => {
    'id': id,
    'agent_id': agentId,
    'source': source.label,
    'source_ref': sourceRef,
    'main_goal': mainGoal,
    'language_code': languageCode,
    'original_user_message': originalUserMessage,
    'goal_tree': goalTree.toJson(),
    'completion_criteria': completionCriteria,
    'impacts': impacts,
    if (targetGraph.isNotEmpty) 'target_graph': targetGraph,
    'previous_results': previousResults,
    'current_step': currentStep,
    'available_tools': availableTools,
    'memory_snapshot': memorySnapshot,
    'auto_approve_sensitive': autoApproveSensitive,
    'is_workflow_auto_execute': isWorkflowAutoExecute,
    if (plan != null) 'plan': plan,
    if (pendingToolName != null) 'pending_tool_name': pendingToolName,
    if (pendingToolArgs != null) 'pending_tool_args': pendingToolArgs,
    'status': status.label,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'completed_at': completedAt?.toIso8601String(),
  };

  factory TaskLedger.fromJson(Map<String, dynamic> json) {
    return TaskLedger(
      id: json['id'] as String,
      agentId: json['agent_id'] as String,
      source: LedgerSourceX.fromLabel(json['source'] as String?),
      sourceRef: json['source_ref'] as String?,
      mainGoal: json['main_goal'] as String? ?? '',
      languageCode: json['language_code'] as String? ?? 'en',
      originalUserMessage: json['original_user_message'] as String? ?? '',
      goalTree: GoalTree.fromJson(
        (json['goal_tree'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      completionCriteria:
          (json['completion_criteria'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      impacts:
          (json['impacts'] as List?)
              ?.whereType<Map>()
              .map((m) => m.cast<String, dynamic>())
              .toList() ??
          const [],
      targetGraph:
          (json['target_graph'] as Map?)?.cast<String, dynamic>() ?? const {},
      previousResults:
          (json['previous_results'] as List?)
              ?.whereType<Map>()
              .map((m) => m.cast<String, dynamic>())
              .toList() ??
          <Map<String, dynamic>>[],
      currentStep: (json['current_step'] as num?)?.toInt() ?? 1,
      availableTools:
          (json['available_tools'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      memorySnapshot: json['memory_snapshot'] as String? ?? '',
      autoApproveSensitive: json['auto_approve_sensitive'] as bool? ?? false,
      isWorkflowAutoExecute: json['is_workflow_auto_execute'] as bool? ?? false,
      plan: (json['plan'] as Map?)?.cast<String, dynamic>(),
      pendingToolName: json['pending_tool_name'] as String?,
      pendingToolArgs: (json['pending_tool_args'] as Map?)
          ?.cast<String, dynamic>(),
      status: LedgerStatusX.fromLabel(json['status'] as String?),
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.now(),
      completedAt: json['completed_at'] != null
          ? DateTime.tryParse(json['completed_at'] as String)
          : null,
    );
  }

  /// Compact human-readable rendering for clarify prompts.
  /// Used when the runtime needs to ask "replace this active task with a
  /// new one?".
  String describeForUser() {
    final remaining = goalTree.subgoals.where((s) => !s.isTerminal).length;
    final total = goalTree.subgoals.length;
    final targetCount = (targetGraph['targets'] as List?)?.length ?? 0;
    final targetText = targetCount == 0 ? '' : ', targets: $targetCount';
    return 'main goal: $mainGoal '
        '(progress: ${total - remaining}/$total subgoals$targetText)';
  }
}

/// SQLite-backed repository for [TaskLedger].
///
/// Stored in its own database (`meow_task_ledgers.db`) following the project
/// convention of one SQLite file per concern.
class TaskLedgerDatabase {
  TaskLedgerDatabase({String? overrideDbPath})
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
        _overrideDbPath ?? '${await getDatabasesPath()}/meow_task_ledgers.db';
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE task_ledgers (
            id TEXT PRIMARY KEY,
            agent_id TEXT NOT NULL,
            source TEXT NOT NULL,
            source_ref TEXT,
            status TEXT NOT NULL DEFAULT 'active',
            main_goal TEXT NOT NULL,
            language_code TEXT NOT NULL DEFAULT 'en',
            original_user_message TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            completed_at TEXT
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_ledgers_active
            ON task_ledgers(agent_id, source, status)
        ''');
      },
    );
  }

  /// Insert or replace a ledger. Returns the [TaskLedger] with its
  /// `updated_at` refreshed.
  Future<TaskLedger> upsert(TaskLedger ledger) async {
    final db = await database;
    final now = DateTime.now();
    ledger.updatedAt = now;
    if (ledger.isTerminal && ledger.completedAt == null) {
      ledger.completedAt = now;
    }
    await db.insert(
      'task_ledgers',
      _toRow(ledger),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return ledger;
  }

  /// Look up the ACTIVE ledger for an (agent, source) pair, if any.
  /// At most one is expected per scope — DB does not enforce uniqueness so
  /// the runtime is responsible for resolving conflicts via clarify.
  ///
  /// [maxAge] guards against a stale "ghost task": a ledger parked long ago
  /// (user walked away mid-task, never resumed) must not silently re-anchor an
  /// unrelated new turn hours later. An active ledger older than [maxAge] is
  /// auto-archived (aborted) and treated as absent. Defaults to null (no age
  /// guard) so lifecycle callers (archive, restore-pending-confirmation) keep
  /// exact behavior; the engine opts in at the context-building call where the
  /// bleed actually happens.
  Future<TaskLedger?> findActive({
    required String agentId,
    required LedgerSource source,
    Duration? maxAge,
  }) async {
    final db = await database;
    final rows = await db.query(
      'task_ledgers',
      where: 'agent_id = ? AND source = ? AND status = ?',
      whereArgs: [agentId, source.label, 'active'],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final ledger = _fromRow(rows.first);
    // Goal tree already complete → the task actually finished but the success
    // path missed archiving (e.g. interrupted right after a confirmation gate).
    // Auto-archive so it can never resurface as a ghost active task.
    if (ledger.goalTree.isNotEmpty && ledger.goalTree.isComplete) {
      ledger.status = LedgerStatus.completed;
      ledger.completedAt = DateTime.now();
      ledger.pendingToolName = null;
      ledger.pendingToolArgs = null;
      await upsert(ledger);
      return null;
    }
    if (maxAge != null) {
      final age = DateTime.now().difference(ledger.updatedAt);
      if (age > maxAge) {
        ledger.status = LedgerStatus.aborted;
        ledger.completedAt = DateTime.now();
        ledger.pendingToolName = null;
        ledger.pendingToolArgs = null;
        await upsert(ledger);
        return null;
      }
    }
    return ledger;
  }

  Future<TaskLedger?> findById(String id) async {
    final db = await database;
    final rows = await db.query(
      'task_ledgers',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Soft-archive: mark terminal, keep the row for audit/debug.
  Future<void> archive(String id, LedgerStatus terminal) async {
    if (terminal == LedgerStatus.active) {
      throw ArgumentError('archive(): terminal must be a terminal status');
    }
    final ledger = await findById(id);
    if (ledger == null) return;
    ledger.status = terminal;
    ledger.completedAt = DateTime.now();
    // Drop any parked confirmation so a terminal ledger can never rehydrate a
    // PendingAction on a future turn.
    ledger.pendingToolName = null;
    ledger.pendingToolArgs = null;
    await upsert(ledger);
  }

  /// Soft-delete on failure so user retry isn't polluted by stale state.
  /// We still keep the row but flip status — caller decides whether to
  /// hard-delete via [delete].
  Future<void> delete(String id) async {
    final db = await database;
    await db.delete('task_ledgers', where: 'id = ?', whereArgs: [id]);
  }

  /// Hard-delete EVERY ledger row for an agent regardless of status.
  /// Used by `/clear` and `/reset` so a fresh session can never rehydrate a
  /// stale task. Returns the number of rows removed.
  Future<int> deleteAllForAgent(String agentId) async {
    final db = await database;
    return db.delete(
      'task_ledgers',
      where: 'agent_id = ?',
      whereArgs: [agentId],
    );
  }

  /// List all active ledgers for an agent. Diagnostic; the runtime should
  /// usually go through [findActive].
  Future<List<TaskLedger>> listActive({required String agentId}) async {
    final db = await database;
    final rows = await db.query(
      'task_ledgers',
      where: 'agent_id = ? AND status = ?',
      whereArgs: [agentId, 'active'],
      orderBy: 'updated_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ───────────────────────────────────────────────────────────────────────
  // Mapping
  // ───────────────────────────────────────────────────────────────────────

  Map<String, dynamic> _toRow(TaskLedger l) => {
    'id': l.id,
    'agent_id': l.agentId,
    'source': l.source.label,
    'source_ref': l.sourceRef,
    'status': l.status.label,
    'main_goal': l.mainGoal,
    'language_code': l.languageCode,
    'original_user_message': l.originalUserMessage,
    'payload_json': jsonEncode(l.toJson()),
    'created_at': l.createdAt.toIso8601String(),
    'updated_at': l.updatedAt.toIso8601String(),
    'completed_at': l.completedAt?.toIso8601String(),
  };

  TaskLedger _fromRow(Map<String, dynamic> row) {
    // payload_json is the source of truth; the dedicated columns exist for
    // querying/indexing.
    final payload =
        jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
    return TaskLedger.fromJson(payload);
  }
}
