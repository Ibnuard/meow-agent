import 'dart:convert';

/// Status of a single subgoal in the [GoalTree].
enum SubgoalStatus { pending, inProgress, done, failed, skipped }

extension SubgoalStatusX on SubgoalStatus {
  String get label => switch (this) {
        SubgoalStatus.pending => 'pending',
        SubgoalStatus.inProgress => 'in_progress',
        SubgoalStatus.done => 'done',
        SubgoalStatus.failed => 'failed',
        SubgoalStatus.skipped => 'skipped',
      };

  static SubgoalStatus fromLabel(String? raw) {
    switch (raw) {
      case 'pending':
        return SubgoalStatus.pending;
      case 'in_progress':
      case 'inProgress':
        return SubgoalStatus.inProgress;
      case 'done':
      case 'complete':
      case 'completed':
        return SubgoalStatus.done;
      case 'failed':
      case 'error':
        return SubgoalStatus.failed;
      case 'skipped':
      case 'skip':
        return SubgoalStatus.skipped;
      default:
        return SubgoalStatus.pending;
    }
  }
}

/// A single sub-objective inside a multi-target task.
///
/// E.g. for "create 3 agents X, Y, Z" the planner emits 3 subgoals,
/// each with its own required slots and completion status.
class Subgoal {
  Subgoal({
    required this.id,
    required this.label,
    Map<String, dynamic>? requiredSlots,
    List<String>? missingSlots,
    this.status = SubgoalStatus.pending,
    this.resultRef,
    this.notes,
  })  : requiredSlots = requiredSlots ?? const {},
        missingSlots = missingSlots ?? const [];

  final String id;
  final String label;

  /// Slots the subgoal needs to be executable. Stable identity for the slot
  /// (e.g. {"name": "Coder", "persona": "..."}).
  final Map<String, dynamic> requiredSlots;

  /// Slot keys that are not yet populated. Empty means subgoal is ready
  /// to execute. Reviewer/planner may update this list across turns.
  final List<String> missingSlots;

  SubgoalStatus status;

  /// Reference to the tool result that satisfied this subgoal.
  /// Used by the reviewer to map executions to subgoals on next turn.
  String? resultRef;

  /// Free-form notes attached during execution (e.g. "agent_id=ag_42").
  String? notes;

  bool get isReady =>
      missingSlots.isEmpty &&
      (status == SubgoalStatus.pending || status == SubgoalStatus.inProgress);

  bool get isTerminal =>
      status == SubgoalStatus.done ||
      status == SubgoalStatus.failed ||
      status == SubgoalStatus.skipped;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        if (requiredSlots.isNotEmpty) 'required_slots': requiredSlots,
        if (missingSlots.isNotEmpty) 'missing_slots': missingSlots,
        'status': status.label,
        if (resultRef != null) 'result_ref': resultRef,
        if (notes != null) 'notes': notes,
      };

  factory Subgoal.fromJson(Map<String, dynamic> json) {
    return Subgoal(
      id: (json['id'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      requiredSlots: (json['required_slots'] as Map?)?.cast<String, dynamic>(),
      missingSlots: (json['missing_slots'] as List?)
          ?.map((e) => e.toString())
          .toList(),
      status: SubgoalStatusX.fromLabel(json['status'] as String?),
      resultRef: json['result_ref'] as String?,
      notes: json['notes'] as String?,
    );
  }
}

/// Multi-target goal structure: replaces the old flat `steps[]` plan.
///
/// Reviewer can only return `status:done` when [isComplete] is true.
/// Multi-target tasks (e.g. "buat 3 agen") MUST be enumerated as separate
/// subgoals — never collapsed into a single flat step.
class GoalTree {
  GoalTree({
    required this.mainGoal,
    List<String>? completionCriteria,
    List<Subgoal>? subgoals,
  })  : completionCriteria = completionCriteria ?? const [],
        subgoals = subgoals ?? [];

  final String mainGoal;
  final List<String> completionCriteria;
  final List<Subgoal> subgoals;

  bool get isEmpty => subgoals.isEmpty;
  bool get isNotEmpty => subgoals.isNotEmpty;

  bool get isComplete =>
      subgoals.isNotEmpty &&
      subgoals.every((s) => s.status == SubgoalStatus.done);

  bool get hasFailed =>
      subgoals.any((s) => s.status == SubgoalStatus.failed);

  /// Next subgoal to work on. `inProgress` first (resume), then `pending`.
  /// Returns null when all subgoals are terminal.
  Subgoal? get nextActionable {
    for (final s in subgoals) {
      if (s.status == SubgoalStatus.inProgress) return s;
    }
    for (final s in subgoals) {
      if (s.status == SubgoalStatus.pending) return s;
    }
    return null;
  }

  Subgoal? findById(String id) {
    for (final s in subgoals) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Apply a status update emitted by the reviewer.
  /// Robust against unknown ids — logs and skips silently.
  bool applyStatusUpdate({
    required String subgoalId,
    required SubgoalStatus status,
    String? resultRef,
    String? notes,
  }) {
    final target = findById(subgoalId);
    if (target == null) return false;
    target.status = status;
    if (resultRef != null) target.resultRef = resultRef;
    if (notes != null) target.notes = notes;
    return true;
  }

  /// Compact human-readable summary for prompt injection.
  String toCompactString() {
    if (subgoals.isEmpty) return 'Goal: $mainGoal';
    final buf = StringBuffer()
      ..writeln('Main goal: $mainGoal');
    if (completionCriteria.isNotEmpty) {
      buf.writeln('Completion criteria:');
      for (final c in completionCriteria) {
        buf.writeln('- $c');
      }
    }
    buf.writeln('Subgoals (${subgoals.length}):');
    for (final s in subgoals) {
      final missing =
          s.missingSlots.isEmpty ? '' : ' [missing:${s.missingSlots.join(",")}]';
      buf.writeln('- [${s.status.label}] ${s.id}: ${s.label}$missing');
    }
    return buf.toString().trim();
  }

  Map<String, dynamic> toJson() => {
        'main_goal': mainGoal,
        if (completionCriteria.isNotEmpty)
          'completion_criteria': completionCriteria,
        'subgoals': subgoals.map((s) => s.toJson()).toList(),
      };

  factory GoalTree.fromJson(Map<String, dynamic> json) {
    return GoalTree(
      mainGoal: (json['main_goal'] ?? json['goal'] ?? '').toString(),
      completionCriteria: (json['completion_criteria'] as List?)
          ?.map((e) => e.toString())
          .toList(),
      subgoals: (json['subgoals'] as List?)
          ?.map((e) => Subgoal.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Build a single-subgoal tree from a legacy analysis (no enumeration).
  /// Used when the planner falls back to flat path or analysis is empty.
  factory GoalTree.singleSubgoal({
    required String mainGoal,
    String? subgoalLabel,
  }) {
    final id = 'sg_main';
    return GoalTree(
      mainGoal: mainGoal,
      subgoals: [
        Subgoal(id: id, label: subgoalLabel ?? mainGoal),
      ],
    );
  }
}

/// Tracks runtime stuck detection — same (tool+args) executed N times in a row.
/// Emits a signal so the runtime can re-plan once before aborting.
class StuckDetector {
  StuckDetector({this.threshold = 3});

  final int threshold;
  final Map<String, int> _counts = {};
  String? _lastKey;

  /// Returns true when the same key has been observed [threshold] times in
  /// a row. The caller should reset after a successful re-plan.
  bool observe({
    required String toolName,
    required Map<String, dynamic> args,
  }) {
    final key = _key(toolName, args);
    if (key == _lastKey) {
      _counts[key] = (_counts[key] ?? 1) + 1;
    } else {
      _counts[key] = 1;
    }
    _lastKey = key;
    return (_counts[key] ?? 0) >= threshold;
  }

  void reset() {
    _counts.clear();
    _lastKey = null;
  }

  static String _key(String toolName, Map<String, dynamic> args) {
    final keys = args.keys.toList()..sort();
    final ordered = <String, dynamic>{for (final k in keys) k: args[k]};
    return '$toolName|${jsonEncode(ordered)}';
  }
}
