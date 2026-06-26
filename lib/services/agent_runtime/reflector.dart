import 'goal_tree.dart';

/// Strategy chosen by the [Reflector].
///
/// Drives the runtime's next move:
/// - [directExecute] → run the loop, no extra preamble
/// - [clarify]      → ask the user one short question first
/// - [autoResolve]  → run preparatory steps silently, then continue (Phase 4 finishes this)
/// - [block]        → refuse with a clear, helpful explanation
enum ReflectionStrategy { directExecute, clarify, autoResolve, block }

extension ReflectionStrategyX on ReflectionStrategy {
  String get label => switch (this) {
    ReflectionStrategy.directExecute => 'direct_execute',
    ReflectionStrategy.clarify => 'clarify',
    ReflectionStrategy.autoResolve => 'auto_resolve',
    ReflectionStrategy.block => 'block',
  };

  static ReflectionStrategy fromLabel(String? raw) {
    switch (raw) {
      case 'direct_execute':
      case 'direct':
      case 'execute':
        return ReflectionStrategy.directExecute;
      case 'clarify':
      case 'ask':
        return ReflectionStrategy.clarify;
      case 'auto_resolve':
      case 'auto':
      case 'resolve':
        return ReflectionStrategy.autoResolve;
      case 'block':
      case 'refuse':
        return ReflectionStrategy.block;
      default:
        return ReflectionStrategy.directExecute;
    }
  }
}

/// One impacted entity discovered during reflection.
///
/// Surfaced to the user when reflection chooses [ReflectionStrategy.autoResolve]
/// or [ReflectionStrategy.block]. Empty when no entities are affected.
class ReflectionImpact {
  const ReflectionImpact({
    required this.entityType,
    required this.entityId,
    required this.entityLabel,
    required this.relation,
    required this.severity,
    required this.autoResolvable,
    this.resolutionHint = '',
    this.sourceTargetId = '',
  });

  final String entityType;
  final String entityId;
  final String entityLabel;
  final String relation;
  final String severity; // low | medium | high
  final bool autoResolvable;
  final String resolutionHint;
  final String sourceTargetId;

  Map<String, dynamic> toJson() => {
    'entity_type': entityType,
    'entity_id': entityId,
    'entity_label': entityLabel,
    'relation': relation,
    'severity': severity,
    'auto_resolvable': autoResolvable,
    'resolution_hint': resolutionHint,
    if (sourceTargetId.isNotEmpty) 'source_target_id': sourceTargetId,
  };

  factory ReflectionImpact.fromJson(Map<String, dynamic> json) =>
      ReflectionImpact(
        entityType: (json['entity_type'] ?? '').toString(),
        entityId: (json['entity_id'] ?? '').toString(),
        entityLabel: (json['entity_label'] ?? '').toString(),
        relation: (json['relation'] ?? '').toString(),
        severity: (json['severity'] ?? 'low').toString(),
        autoResolvable: json['auto_resolvable'] as bool? ?? false,
        resolutionHint: (json['resolution_hint'] ?? '').toString(),
        sourceTargetId: (json['source_target_id'] ?? '').toString(),
      );
}

/// One user-requested target discovered during reflection.
///
/// This is the machine-readable counterpart to a subgoal label. It lets the
/// runtime apply deterministic policies and connect impact analysis to the
/// actual target set instead of relying on narrative text.
class ReflectionTarget {
  const ReflectionTarget({
    required this.subgoalId,
    required this.operation,
    required this.entityType,
    this.entityId = '',
    this.entityLabel = '',
    this.selector = const {},
  });

  final String subgoalId;
  final String operation;
  final String entityType;
  final String entityId;
  final String entityLabel;
  final Map<String, dynamic> selector;

  Map<String, dynamic> toJson() => {
    'subgoal_id': subgoalId,
    'operation': operation,
    'entity_type': entityType,
    if (entityId.isNotEmpty) 'entity_id': entityId,
    if (entityLabel.isNotEmpty) 'entity_label': entityLabel,
    if (selector.isNotEmpty) 'selector': selector,
  };

  factory ReflectionTarget.fromJson(
    Map<String, dynamic> json,
  ) => ReflectionTarget(
    subgoalId: (json['subgoal_id'] ?? json['subgoalId'] ?? '').toString(),
    operation: (json['operation'] ?? '').toString(),
    entityType: (json['entity_type'] ?? json['entityType'] ?? '').toString(),
    entityId: (json['entity_id'] ?? json['entityId'] ?? '').toString(),
    entityLabel: (json['entity_label'] ?? json['entityLabel'] ?? '').toString(),
    selector: (json['selector'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
}

/// Output of one reflection turn.
///
/// Carries enough state for the runtime to decide whether to:
/// - run the execute loop directly (`strategy == directExecute`)
/// - ask one clarifying question (`strategy == clarify`, `clarifyQuestions[0]`)
/// - run prep steps silently then continue (`strategy == autoResolve`)
/// - refuse politely (`strategy == block`, `blockReason`)
class ReflectionOutput {
  ReflectionOutput({
    required this.strategy,
    required this.goalTree,
    this.targets = const [],
    this.impacts = const [],
    this.clarifyQuestions = const [],
    this.blockReason = '',
    this.reasoning = '',
    this.narrative = '',
    this.nextNarrative = '',
    this.degraded = false,
  });

  final ReflectionStrategy strategy;
  final GoalTree goalTree;
  final List<ReflectionTarget> targets;
  final List<ReflectionImpact> impacts;
  final List<String> clarifyQuestions;
  final String blockReason;
  final String reasoning;

  /// LLM-generated POV-AI sentence in the user's language describing what
  /// the agent is currently thinking. Surfaced as the ambient narrative
  /// bubble. Empty when the model omitted it.
  final String narrative;

  /// LLM-generated, forward-looking thought shown immediately before the
  /// runtime enters the next phase. Empty means the runtime uses its safe
  /// deterministic fallback.
  final String nextNarrative;

  /// True when the reflector failed (parse / network) and we degraded to
  /// a directExecute fallback. Used for logging only.
  final bool degraded;

  bool get hasImpacts => impacts.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'strategy': strategy.label,
    'goal_tree': goalTree.toJson(),
    if (targets.isNotEmpty) 'targets': targets.map((e) => e.toJson()).toList(),
    if (impacts.isNotEmpty) 'impacts': impacts.map((e) => e.toJson()).toList(),
    if (clarifyQuestions.isNotEmpty) 'clarify_questions': clarifyQuestions,
    if (blockReason.isNotEmpty) 'block_reason': blockReason,
    if (reasoning.isNotEmpty) 'reasoning': reasoning,
    if (narrative.isNotEmpty) 'narrative': narrative,
    if (nextNarrative.isNotEmpty) 'next_narrative': nextNarrative,
    if (degraded) 'degraded': true,
  };
}

// ─── Reflector class removed ─────────────────────────────────────────────────
// The Reflector class was replaced by the unified Classifier (see
// classifier.dart). Its prompt builder and LLM call logic are no longer
// used. The data types above (ReflectionStrategy, ReflectionImpact,
// ReflectionTarget, ReflectionOutput) are still used by the classifier
// and runtime engine, so they stay.
