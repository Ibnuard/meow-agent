import 'ecosystem_snapshot.dart';
import 'goal_tree.dart';
import 'language_detector.dart';
import 'language_registry.dart';
import 'reflector.dart';
import 'runtime_models.dart';
import 'snapshot_target_resolver.dart';
import 'target_reference_utils.dart';

enum ResolvedTargetStatus { eligible, skipped, missing, ambiguous, ineligible }

extension ResolvedTargetStatusX on ResolvedTargetStatus {
  String get label => switch (this) {
    ResolvedTargetStatus.eligible => 'eligible',
    ResolvedTargetStatus.skipped => 'skipped',
    ResolvedTargetStatus.missing => 'missing',
    ResolvedTargetStatus.ambiguous => 'ambiguous',
    ResolvedTargetStatus.ineligible => 'ineligible',
  };

  static ResolvedTargetStatus fromLabel(String? raw) {
    switch (raw) {
      case 'eligible':
        return ResolvedTargetStatus.eligible;
      case 'skipped':
        return ResolvedTargetStatus.skipped;
      case 'missing':
        return ResolvedTargetStatus.missing;
      case 'ambiguous':
        return ResolvedTargetStatus.ambiguous;
      case 'ineligible':
        return ResolvedTargetStatus.ineligible;
      default:
        return ResolvedTargetStatus.eligible;
    }
  }
}

class ResolvedTarget {
  const ResolvedTarget({
    required this.key,
    required this.subgoalId,
    required this.operation,
    required this.entityType,
    this.entityId = '',
    this.entityLabel = '',
    this.status = ResolvedTargetStatus.eligible,
    this.reason = '',
    this.selector = const {},
  });

  final String key;
  final String subgoalId;
  final String operation;
  final String entityType;
  final String entityId;
  final String entityLabel;
  final ResolvedTargetStatus status;
  final String reason;
  final Map<String, dynamic> selector;

  bool get isEligible => status == ResolvedTargetStatus.eligible;
  bool get isSkipped => status == ResolvedTargetStatus.skipped;
  bool get isBlocking =>
      status == ResolvedTargetStatus.missing ||
      status == ResolvedTargetStatus.ambiguous ||
      status == ResolvedTargetStatus.ineligible;

  ResolvedTarget copyWith({
    String? key,
    String? subgoalId,
    String? operation,
    String? entityType,
    String? entityId,
    String? entityLabel,
    ResolvedTargetStatus? status,
    String? reason,
    Map<String, dynamic>? selector,
  }) {
    return ResolvedTarget(
      key: key ?? this.key,
      subgoalId: subgoalId ?? this.subgoalId,
      operation: operation ?? this.operation,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      entityLabel: entityLabel ?? this.entityLabel,
      status: status ?? this.status,
      reason: reason ?? this.reason,
      selector: selector ?? this.selector,
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'subgoal_id': subgoalId,
    'operation': operation,
    'entity_type': entityType,
    if (entityId.isNotEmpty) 'entity_id': entityId,
    if (entityLabel.isNotEmpty) 'entity_label': entityLabel,
    'status': status.label,
    if (reason.isNotEmpty) 'reason': reason,
    if (selector.isNotEmpty) 'selector': selector,
  };

  factory ResolvedTarget.fromJson(Map<String, dynamic> json) => ResolvedTarget(
    key: (json['key'] ?? '').toString(),
    subgoalId: (json['subgoal_id'] ?? '').toString(),
    operation: (json['operation'] ?? '').toString(),
    entityType: (json['entity_type'] ?? '').toString(),
    entityId: (json['entity_id'] ?? '').toString(),
    entityLabel: (json['entity_label'] ?? '').toString(),
    status: ResolvedTargetStatusX.fromLabel(json['status'] as String?),
    reason: (json['reason'] ?? '').toString(),
    selector: (json['selector'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
}

class TargetResolutionGraph {
  const TargetResolutionGraph({
    this.targets = const [],
    this.originalImpactCount = 0,
    this.filteredImpactCount = 0,
  });

  final List<ResolvedTarget> targets;
  final int originalImpactCount;
  final int filteredImpactCount;

  bool get isEmpty => targets.isEmpty;
  bool get isNotEmpty => targets.isNotEmpty;
  bool get hasEligible => targets.any((t) => t.isEligible);
  bool get hasSkipped => targets.any((t) => t.isSkipped);
  bool get hasBlocking => targets.any((t) => t.isBlocking);
  bool get filteredImpacts => filteredImpactCount < originalImpactCount;

  List<ResolvedTarget> get eligibleTargets =>
      targets.where((t) => t.isEligible).toList(growable: false);

  List<ResolvedTarget> get skippedTargets =>
      targets.where((t) => t.isSkipped).toList(growable: false);

  List<ResolvedTarget> get blockingTargets =>
      targets.where((t) => t.isBlocking).toList(growable: false);

  Map<String, dynamic> toJson() => {
    'targets': targets.map((t) => t.toJson()).toList(),
    'original_impact_count': originalImpactCount,
    'filtered_impact_count': filteredImpactCount,
  };

  factory TargetResolutionGraph.fromJson(Map<String, dynamic> json) {
    final rawTargets = json['targets'] as List?;
    return TargetResolutionGraph(
      targets: rawTargets == null
          ? const []
          : rawTargets
                .whereType<Map>()
                .map((m) => ResolvedTarget.fromJson(m.cast<String, dynamic>()))
                .toList(growable: false),
      originalImpactCount:
          (json['original_impact_count'] as num?)?.toInt() ?? 0,
      filteredImpactCount:
          (json['filtered_impact_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class TargetResolutionResult {
  const TargetResolutionResult({required this.reflection, required this.graph});

  final ReflectionOutput reflection;
  final TargetResolutionGraph graph;
}

class TargetResolver {
  TargetResolver._();

  static TargetResolutionResult resolveReflection({
    required ReflectionOutput reflection,
    required EcosystemSnapshot snapshot,
    required AgentRuntimeRequest request,
    required DetectedLanguage language,
  }) {
    // STEP 0: Generic bulk-selector expansion.
    //
    // When the reflector emits a target like {entity_type:workflow,
    // entity_label:"all"} or any subgoal whose target uses a bulk quantifier,
    // fan it out to one concrete target per matching snapshot entity BEFORE
    // normal resolution. Applies to every snapshot-backed entity type and
    // every non-create operation. This is what guarantees a request like
    // "set semua workflow ke agen X" decomposes into N subgoals instead of
    // collapsing into a single ambiguous step.
    final expanded = _expandBulkSelectors(reflection, snapshot);

    final resolved = _resolveTargets(
      reflection: expanded,
      snapshot: snapshot,
      request: request,
    );
    if (resolved.isEmpty) {
      return TargetResolutionResult(
        reflection: expanded,
        graph: TargetResolutionGraph(
          targets: const [],
          originalImpactCount: expanded.impacts.length,
          filteredImpactCount: expanded.impacts.length,
        ),
      );
    }

    final filteredSubgoals = _filterSubgoals(
      expanded.goalTree.subgoals,
      resolved,
    );
    final filteredImpacts = _filterImpacts(expanded.impacts, resolved);
    final graph = TargetResolutionGraph(
      targets: resolved,
      originalImpactCount: expanded.impacts.length,
      filteredImpactCount: filteredImpacts.length,
    );

    var strategy = expanded.strategy;
    var clarifyQuestions = expanded.clarifyQuestions;
    var blockReason = expanded.blockReason;
    final hasMissingSlots = filteredSubgoals.any(
      (s) => s.missingSlots.isNotEmpty,
    );

    if (graph.hasBlocking) {
      strategy = ReflectionStrategy.clarify;
      clarifyQuestions = [_clarifyForBlocking(graph.blockingTargets, language)];
      blockReason = '';
    } else if (!graph.hasEligible && graph.hasSkipped) {
      strategy = ReflectionStrategy.block;
      clarifyQuestions = const [];
      blockReason = _blockForNoEligibleTargets(graph.skippedTargets, language);
    } else if (!hasMissingSlots &&
        filteredImpacts.isEmpty &&
        (strategy == ReflectionStrategy.clarify ||
            strategy == ReflectionStrategy.block ||
            strategy == ReflectionStrategy.autoResolve)) {
      strategy = ReflectionStrategy.directExecute;
      clarifyQuestions = const [];
      blockReason = '';
    }

    final goalTree = GoalTree(
      mainGoal: expanded.goalTree.mainGoal,
      completionCriteria: expanded.goalTree.completionCriteria,
      subgoals: filteredSubgoals,
    );

    return TargetResolutionResult(
      graph: graph,
      reflection: ReflectionOutput(
        strategy: strategy,
        goalTree: goalTree,
        targets: [
          for (final target in graph.targets)
            ReflectionTarget(
              subgoalId: target.subgoalId,
              operation: target.operation,
              entityType: target.entityType,
              entityId: target.entityId,
              entityLabel: target.entityLabel,
              selector: target.selector,
            ),
        ],
        impacts: filteredImpacts,
        clarifyQuestions: clarifyQuestions,
        blockReason: blockReason,
        reasoning: [
          expanded.reasoning,
          if (graph.hasSkipped)
            'Runtime skipped ineligible targets before impact handling.',
          if (graph.filteredImpacts)
            'Runtime removed impacts that were not linked to eligible targets.',
        ].where((s) => s.trim().isNotEmpty).join(' '),
        narrative: expanded.narrative,
        nextNarrative: expanded.nextNarrative,
        degraded: expanded.degraded,
      ),
    );
  }

  // ─── Bulk selector expansion ───────────────────────────────────────────────

  /// Quantifier vocabulary that signals "all entities of this type". Used to
  /// fan out bulk requests deterministically from the snapshot.
  ///
  /// Kept generic across languages and entity types. Adding a new language
  /// only requires extending this set; the rest of the pipeline picks it up
  /// for free.
  static const Set<String> _bulkKeywords = {
    // English
    'all', 'every', 'each', 'any', 'everyone',
    // Indonesian
    'semua', 'setiap', 'seluruh', 'tiap', 'segala',
    // Wildcard
    '*',
  };

  /// True when the label is exactly a bulk quantifier or contains one as a
  /// standalone token (e.g. "all workflows" → all is a token; "semua agen" →
  /// semua is a token). Multi-word phrases like "masing-masing" are also
  /// matched as substrings to keep the rule forgiving.
  static bool _isBulkLabel(String label) {
    final n = _normalize(label);
    if (n.isEmpty) return false;
    if (_bulkKeywords.contains(n)) return true;
    final tokens = n
        .split(RegExp(r'[^a-z0-9*\u00C0-\u024F]+'))
        .where((t) => t.isNotEmpty)
        .toSet();
    for (final kw in _bulkKeywords) {
      if (tokens.contains(kw)) return true;
    }
    // Hyphenated forms like "masing-masing" or "each-of-them".
    final hyphenated = n.replaceAll('-', ' ');
    final hyphenTokens = hyphenated
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toSet();
    for (final kw in _bulkKeywords) {
      if (hyphenTokens.contains(kw)) return true;
    }
    return false;
  }

  /// True when the selector map declares bulk scope explicitly. Common shapes
  /// the reflector might emit:
  /// - {"scope": "all"}
  /// - {"all": true}
  /// - {"filter": "*"}
  /// - {"match": "all"}
  static bool _isBulkSelector(Map<String, dynamic> selector) {
    if (selector.isEmpty) return false;
    final scope = selector['scope']?.toString().toLowerCase() ?? '';
    if (scope == 'all' || scope == '*' || scope == 'every') return true;
    final all = selector['all'];
    if (all == true) return true;
    final filter = selector['filter']?.toString().toLowerCase() ?? '';
    if (filter == '*' || filter == 'all' || filter == 'every') return true;
    final match = selector['match']?.toString().toLowerCase() ?? '';
    if (match == 'all' || match == 'every') return true;
    return false;
  }

  /// True when the selector declares a structured, language-agnostic predicate
  /// over an entity field. The reflector emits this for requests like
  /// "delete agents ending with Don" (in ANY language) instead of enumerating
  /// names itself:
  ///
  ///   {"scope":"predicate","field":"name","op":"ends_with",
  ///    "value":"Don","case_sensitive":false}
  ///
  /// The RUNTIME (not the LLM) evaluates the predicate against live snapshot
  /// state, so it can never invent a non-existent entity — the model only
  /// supplies the pattern.
  static bool _isPredicateSelector(Map<String, dynamic> selector) {
    if (selector.isEmpty) return false;
    final scope = selector['scope']?.toString().toLowerCase() ?? '';
    if (scope != 'predicate' && scope != 'filter_by') return false;
    final op = _predicateOp(selector);
    return op.isNotEmpty;
  }

  /// Supported predicate operators (language-agnostic, structural).
  static const Set<String> _predicateOps = {
    'ends_with',
    'starts_with',
    'contains',
    'equals',
    'regex',
  };

  static String _predicateOp(Map<String, dynamic> selector) {
    final raw = (selector['op'] ?? selector['operator'] ?? '')
        .toString()
        .toLowerCase()
        .trim()
        .replaceAll('-', '_')
        .replaceAll(' ', '_');
    // Normalize a few common synonyms the model might emit.
    const synonyms = {
      'endswith': 'ends_with',
      'suffix': 'ends_with',
      'startswith': 'starts_with',
      'prefix': 'starts_with',
      'includes': 'contains',
      'has': 'contains',
      'eq': 'equals',
      'is': 'equals',
      'matches': 'regex',
      'pattern': 'regex',
    };
    final normalized = synonyms[raw] ?? raw;
    return _predicateOps.contains(normalized) ? normalized : '';
  }

  /// Evaluate a predicate selector against a single entity.
  ///
  /// Resolves [selector.field] against [entity.metadata] first (per-entity-type
  /// extended fields like workflow.agent_name or module.enabled), then against
  /// [entity.id] (for field == "id"), and finally against [entity.label]
  /// (the human-readable name/title). This is fully generic — adding metadata
  /// to [_entities] for a new entity type is all that's needed.
  static bool _matchesPredicate(
    Map<String, dynamic> selector,
    _EntityMatch entity,
  ) {
    final op = _predicateOp(selector);
    if (op.isEmpty) return false;
    final value = (selector['value'] ?? selector['pattern'] ?? '').toString();
    if (value.isEmpty) return false;

    final field = (selector['field'] ?? 'name').toString().toLowerCase();
    final subject = entity.metadata.containsKey(field)
        ? (entity.metadata[field]?.toString() ?? '')
        : (field == 'id')
        ? entity.id
        : entity.label;

    final caseSensitive = selector['case_sensitive'] == true;
    final a = caseSensitive ? subject : subject.toLowerCase();
    final b = caseSensitive ? value : value.toLowerCase();

    switch (op) {
      case 'ends_with':
        return a.endsWith(b);
      case 'starts_with':
        return a.startsWith(b);
      case 'contains':
        return a.contains(b);
      case 'equals':
        return a == b;
      case 'regex':
        try {
          return RegExp(value, caseSensitive: caseSensitive).hasMatch(subject);
        } catch (_) {
          return false; // Invalid regex never matches — fail safe.
        }
      default:
        return false;
    }
  }

  /// Operations that may target an existing entity collection in bulk. Create
  /// is intentionally absent — `create all X` is never a valid bulk op and is
  /// treated as ambiguous so the LLM/reflector can clarify.
  static const Set<String> _bulkEligibleOperations = {
    'delete',
    'update',
    'rename',
    'toggle',
    'read',
    'list',
  };

  /// Walk the reflector output and replace any bulk-marked target with one
  /// concrete target per matching snapshot entity. Subgoals are forked in
  /// place so the goal tree carries the full plan downstream.
  static ReflectionOutput _expandBulkSelectors(
    ReflectionOutput reflection,
    EcosystemSnapshot snapshot,
  ) {
    final seedTargets = reflection.targets.isNotEmpty
        ? reflection.targets
        : _targetsFromGoalTree(reflection.goalTree, snapshot);
    if (seedTargets.isEmpty) return reflection;

    final expandedTargets = <ReflectionTarget>[];
    final replacementsBySubgoalId = <String, List<Subgoal>>{};
    var didExpand = false;

    for (var i = 0; i < seedTargets.length; i++) {
      final seed = seedTargets[i];
      final expansion = _maybeExpandBulk(
        seed: seed,
        tree: reflection.goalTree,
        snapshot: snapshot,
        index: i,
      );
      if (expansion == null) {
        expandedTargets.add(seed);
        continue;
      }
      didExpand = true;
      expandedTargets.addAll(expansion.targets);
      replacementsBySubgoalId[expansion.originSubgoalId] = expansion.subgoals;
    }

    if (!didExpand) return reflection;

    // Rebuild subgoal list. Replace each origin in place, append synthetic
    // ones (those with no matching origin subgoal) at the end.
    final newSubgoals = <Subgoal>[];
    for (final subgoal in reflection.goalTree.subgoals) {
      final replacement = replacementsBySubgoalId.remove(subgoal.id);
      if (replacement != null) {
        newSubgoals.addAll(replacement);
      } else {
        newSubgoals.add(subgoal);
      }
    }
    for (final synthetic in replacementsBySubgoalId.values) {
      newSubgoals.addAll(synthetic);
    }

    final newTree = GoalTree(
      mainGoal: reflection.goalTree.mainGoal,
      completionCriteria: reflection.goalTree.completionCriteria,
      subgoals: newSubgoals,
    );

    return ReflectionOutput(
      strategy: reflection.strategy,
      goalTree: newTree,
      targets: expandedTargets,
      impacts: reflection.impacts,
      clarifyQuestions: reflection.clarifyQuestions,
      blockReason: reflection.blockReason,
      reasoning: [
        reflection.reasoning,
        'Runtime fanned out bulk selector targets from snapshot.',
      ].where((s) => s.trim().isNotEmpty).join(' '),
      narrative: reflection.narrative,
      nextNarrative: reflection.nextNarrative,
      degraded: reflection.degraded,
    );
  }

  static _BulkExpansion? _maybeExpandBulk({
    required ReflectionTarget seed,
    required GoalTree tree,
    required EcosystemSnapshot snapshot,
    required int index,
  }) {
    final entityType = _normalize(seed.entityType);
    if (!_isSnapshotBackedEntity(entityType)) return null;

    final operation = _normalize(seed.operation);
    if (!_bulkEligibleOperations.contains(operation)) return null;

    // Already concrete (snapshot id known) — nothing to expand.
    if (seed.entityId.trim().isNotEmpty) return null;

    final isPredicate = _isPredicateSelector(seed.selector);
    final isBulk =
        _isBulkLabel(seed.entityLabel) ||
        _isBulkSelector(seed.selector) ||
        isPredicate;
    if (!isBulk) return null;

    final allEntities = _entities(snapshot, entityType);
    if (allEntities.isEmpty) return null;

    // Predicate selectors fan out only to entities the structured predicate
    // matches (evaluated by the runtime against live snapshot state — the LLM
    // never enumerates names). A predicate that matches nothing yields no
    // targets, so the caller surfaces an honest empty-result rather than
    // acting on a guessed entity.
    final entities = isPredicate
        ? allEntities
              .where((e) => _matchesPredicate(seed.selector, e))
              .toList(growable: false)
        : allEntities;
    if (entities.isEmpty) return null;

    final originId = seed.subgoalId.isEmpty ? '__bulk_$index' : seed.subgoalId;
    Subgoal? origin;
    for (final s in tree.subgoals) {
      if (s.id == originId) {
        origin = s;
        break;
      }
    }

    final targets = <ReflectionTarget>[];
    final subgoals = <Subgoal>[];
    for (var k = 0; k < entities.length; k++) {
      final entity = entities[k];
      final id = '${originId}_t${k + 1}';
      targets.add(
        ReflectionTarget(
          subgoalId: id,
          operation: seed.operation,
          entityType: seed.entityType,
          entityId: entity.id,
          entityLabel: entity.label,
          selector: seed.selector,
        ),
      );
      final fallbackLabel = '${seed.operation} $entityType ${entity.label}';
      subgoals.add(
        Subgoal(
          id: id,
          label: origin != null
              ? '${origin.label} → ${entity.label}'
              : fallbackLabel,
          requiredSlots: origin?.requiredSlots ?? const {},
          missingSlots: origin?.missingSlots ?? const [],
        ),
      );
    }

    return _BulkExpansion(
      originSubgoalId: originId,
      targets: targets,
      subgoals: subgoals,
    );
  }

  static List<ResolvedTarget> _resolveTargets({
    required ReflectionOutput reflection,
    required EcosystemSnapshot snapshot,
    required AgentRuntimeRequest request,
  }) {
    final current = _currentAgent(snapshot, request);
    final seedTargets = reflection.targets.isNotEmpty
        ? reflection.targets
        : _targetsFromGoalTree(reflection.goalTree, snapshot);

    final out = <ResolvedTarget>[];
    for (var i = 0; i < seedTargets.length; i++) {
      final seed = seedTargets[i];
      final entityType = _entityTypeForSeed(seed);
      final operation = _operationForSeed(seed, entityType);
      final activeAgentId = current == null || current.id.isEmpty
          ? request.agentId
          : current.id;
      final activeAgentLabel = current == null || current.name.isEmpty
          ? request.agentName
          : current.name;
      var entityId = seed.entityId;
      var entityLabel = seed.entityLabel;
      var selector = seed.selector;
      final referencesCurrentAgent =
          entityType == 'agent' &&
          (TargetReferenceUtils.isCurrentAgentReference(entityId) ||
              TargetReferenceUtils.isCurrentAgentReference(entityLabel));
      if (referencesCurrentAgent) {
        if (activeAgentId.isNotEmpty) entityId = activeAgentId;
        if (activeAgentLabel.isNotEmpty) entityLabel = activeAgentLabel;
        selector = {...selector, 'resolved_reference': 'current_agent'};
      }
      final match = _matchEntity(
        entityType: entityType,
        entityId: entityId,
        entityLabel: entityLabel,
        snapshot: snapshot,
      );
      var resolved = ResolvedTarget(
        key: _targetKey(seed, i),
        subgoalId: seed.subgoalId.isEmpty ? 'sg${i + 1}' : seed.subgoalId,
        operation: operation.isEmpty ? 'unknown' : operation,
        entityType: entityType.isEmpty ? match.entityType : entityType,
        entityId: match.id,
        entityLabel: match.label.isNotEmpty ? match.label : entityLabel,
        selector: selector,
      );

      resolved = _resolvePeerAgentPathTarget(
        resolved: resolved,
        snapshot: snapshot,
        request: request,
      );

      resolved = _guardAgentReadTarget(
        resolved: resolved,
        request: request,
        activeAgentId: activeAgentId,
      );

      if (_requiresSnapshotTarget(entityType, operation) &&
          resolved.entityId.isEmpty) {
        final nearMatch = SnapshotTargetResolver.resolve(
          snapshot: snapshot,
          entityType: entityType,
          entityLabel: entityLabel.isNotEmpty
              ? entityLabel
              : resolved.entityLabel,
        );
        resolved = !nearMatch.isAmbiguous
            ? resolved.copyWith(
                status: ResolvedTargetStatus.missing,
                reason: 'target_not_found',
              )
            : resolved.copyWith(
                entityId: nearMatch.id,
                status: ResolvedTargetStatus.ambiguous,
                reason: 'target_needs_confirmation',
                selector: {
                  ...resolved.selector,
                  'suggestions': nearMatch.suggestions,
                },
              );
      }

      if (current != null &&
          resolved.entityType == 'agent' &&
          resolved.operation == 'delete' &&
          resolved.entityId == current.id) {
        resolved = resolved.copyWith(
          status: ResolvedTargetStatus.skipped,
          reason: 'current_active_agent',
        );
      }

      out.add(resolved);
    }
    return out;
  }

  static ResolvedTarget _resolvePeerAgentPathTarget({
    required ResolvedTarget resolved,
    required EcosystemSnapshot snapshot,
    required AgentRuntimeRequest request,
  }) {
    if (resolved.entityType != 'file' || snapshot.agents.isEmpty) {
      return resolved;
    }
    final peerPath = TargetReferenceUtils.parsePeerAgentPath(
      resolved.entityLabel,
    );
    if (peerPath == null) return resolved;

    final typedName = TargetReferenceUtils.displayNameFromWorkspaceSegment(
      peerPath.agentSegment,
    );
    final match = SnapshotTargetResolver.resolve(
      snapshot: snapshot,
      entityType: 'agent',
      entityLabel: typedName,
    );
    final selector = {
      ...resolved.selector,
      'path': peerPath.originalPath,
      'agent_segment': peerPath.agentSegment,
      if (match.suggestions.isNotEmpty) 'suggestions': match.suggestions,
    };

    if (match.isExact) {
      final userNamedExactAgent =
          TargetReferenceUtils.messageMentionsExactAgent(
            request.userMessage,
            match.label,
          );
      if (!userNamedExactAgent) {
        return resolved.copyWith(
          entityId: match.id,
          entityLabel: match.label,
          status: ResolvedTargetStatus.ambiguous,
          reason: 'agent_path_target_needs_confirmation',
          selector: selector,
        );
      }
      return resolved.copyWith(
        entityId: match.id,
        entityLabel: TargetReferenceUtils.canonicalPeerAgentPath(
          peerPath,
          match.label,
        ),
        selector: selector,
      );
    }

    if (match.isAmbiguous) {
      return resolved.copyWith(
        entityId: match.id,
        entityLabel: typedName,
        status: ResolvedTargetStatus.ambiguous,
        reason: 'agent_path_target_needs_confirmation',
        selector: selector,
      );
    }

    return resolved.copyWith(
      entityLabel: typedName,
      status: ResolvedTargetStatus.missing,
      reason: 'agent_path_target_not_found',
      selector: selector,
    );
  }

  /// Guard non-destructive agent READ targets against silent cross-turn bleed.
  ///
  /// The reflector can emit an agent label that leaked from a PRIOR turn (e.g.
  /// the user deleted "agent C" and listed peers last turn, then asks "what is
  /// your personality?" this turn). An exact snapshot match on that stale label
  /// fills [resolved.entityId] and short-circuits every downstream safety net,
  /// silently answering about the wrong agent.
  ///
  /// Scope is deliberately narrow — this only touches the SILENT path:
  /// - Read-only ops only (read/get/list). Destructive ops (delete/update/...)
  ///   already pass through a user confirmation gate, so a wrong target there
  ///   is visible and correctable; we must not downgrade a legitimately
  ///   reflector-resolved delete.
  /// - Bulk/predicate targets are skipped — those are fanned out by the runtime
  ///   from live snapshot state, not from a model-supplied label, so they are
  ///   trustworthy.
  ///
  /// When a read target is NOT the active agent and the literal user message
  /// does NOT name it, the label leaked from history → rebind to the active
  /// agent (a pronoun/self question like "your personality" is about the
  /// current agent). This mirrors the proven check already used for
  /// peer-agent FILE paths in [_resolvePeerAgentPathTarget].
  static ResolvedTarget _guardAgentReadTarget({
    required ResolvedTarget resolved,
    required AgentRuntimeRequest request,
    required String activeAgentId,
  }) {
    if (resolved.entityType != 'agent') return resolved;
    if (resolved.entityId.isEmpty) return resolved;
    if (!resolved.isEligible) return resolved;
    // Only the silent read path is guarded — see doc above.
    if (!_isReadOnlyOperation(resolved.operation)) return resolved;
    // Runtime-fanned bulk/predicate targets are trustworthy, not leaked labels.
    if (_isBulkSelector(resolved.selector) ||
        _isPredicateSelector(resolved.selector)) {
      return resolved;
    }
    // Already pinned to the active agent upstream — nothing to guard.
    if (resolved.selector['resolved_reference'] == 'current_agent') {
      return resolved;
    }
    if (activeAgentId.isEmpty) return resolved;
    if (resolved.entityId == activeAgentId) return resolved;

    final userNamedExactAgent = TargetReferenceUtils.messageMentionsExactAgent(
      request.userMessage,
      resolved.entityLabel,
    );
    if (userNamedExactAgent) return resolved;

    // A self-ish read with a target the user did not name this turn → the
    // label leaked from history. Bind to the active agent.
    return resolved.copyWith(
      entityId: activeAgentId,
      entityLabel: request.agentName.isNotEmpty
          ? request.agentName
          : resolved.entityLabel,
      selector: {
        ...resolved.selector,
        'resolved_reference': 'current_agent',
        'rebound_from': resolved.entityLabel,
      },
    );
  }

  static List<ReflectionTarget> _targetsFromGoalTree(
    GoalTree goalTree,
    EcosystemSnapshot snapshot,
  ) {
    final out = <ReflectionTarget>[];
    for (final subgoal in goalTree.subgoals) {
      var operation = _slotString(subgoal, const [
        '_operation',
        'operation',
        'action',
      ]);
      var entityType = _slotString(subgoal, const [
        '_entity_type',
        'entity_type',
        'entityType',
        'target_type',
        'targetType',
      ]);
      final entityId = _slotString(subgoal, const [
        'id',
        'agentId',
        'workflowId',
        'providerId',
        'moduleId',
      ]);
      final label = _slotString(subgoal, const [
        'name',
        'agentName',
        'workflowName',
        'title',
        'provider',
        'providerName',
        'module',
        'label',
        'target',
        'targetName',
        'target_name',
        'path',
        'file',
        'url',
        'package',
      ]);
      final pathLike = _pathLikeValue([
        subgoal.label,
        entityId,
        label,
        for (final value in subgoal.requiredSlots.values)
          value?.toString() ?? '',
      ]);
      if (pathLike != null) {
        operation = operation.isEmpty
            ? _inferReadOnlyOperation(subgoal.label)
            : operation;
        entityType = 'file';
        out.add(
          ReflectionTarget(
            subgoalId: subgoal.id,
            operation: operation.isEmpty ? 'read' : operation,
            entityType: entityType,
            entityId: '',
            entityLabel: pathLike,
          ),
        );
        continue;
      }

      final matches = _entityMentionsForSubgoal(subgoal, snapshot);
      if (matches.isEmpty && (operation.isNotEmpty || entityType.isNotEmpty)) {
        out.add(
          ReflectionTarget(
            subgoalId: subgoal.id,
            operation: operation,
            entityType: entityType,
            entityId: entityId,
            entityLabel: label,
          ),
        );
        continue;
      }
      for (final match in matches) {
        out.add(
          ReflectionTarget(
            subgoalId: subgoal.id,
            operation: operation,
            entityType: entityType.isNotEmpty ? entityType : match.entityType,
            entityId: entityId.isNotEmpty ? entityId : match.id,
            entityLabel: label.isNotEmpty ? label : match.label,
          ),
        );
      }
    }
    return out;
  }

  static List<Subgoal> _filterSubgoals(
    List<Subgoal> subgoals,
    List<ResolvedTarget> targets,
  ) {
    final removeSubgoalIds = <String>{};
    for (final subgoal in subgoals) {
      final owned = targets
          .where((t) => t.subgoalId == subgoal.id)
          .toList(growable: false);
      if (owned.isNotEmpty &&
          owned.every((t) => t.status == ResolvedTargetStatus.skipped)) {
        removeSubgoalIds.add(subgoal.id);
      }
    }
    return [
      for (final subgoal in subgoals)
        if (!removeSubgoalIds.contains(subgoal.id)) subgoal,
    ];
  }

  static List<ReflectionImpact> _filterImpacts(
    List<ReflectionImpact> impacts,
    List<ResolvedTarget> targets,
  ) {
    final eligible = targets
        .where((t) => t.isEligible && !_isReadOnlyOperation(t.operation))
        .toList(growable: false);
    if (impacts.isEmpty || eligible.isEmpty) return const [];

    final targetByKey = {
      for (final target in targets) target.key: target,
      for (final target in targets) target.subgoalId: target,
      for (final target in targets)
        if (target.entityId.isNotEmpty) target.entityId: target,
    };

    return [
      for (final impact in impacts)
        if (_impactBelongsToEligibleTarget(impact, targetByKey, eligible))
          impact,
    ];
  }

  static bool _impactBelongsToEligibleTarget(
    ReflectionImpact impact,
    Map<String, ResolvedTarget> targetByKey,
    List<ResolvedTarget> eligible,
  ) {
    if (impact.sourceTargetId.isNotEmpty) {
      final target = targetByKey[impact.sourceTargetId];
      return target != null &&
          target.isEligible &&
          !_isReadOnlyOperation(target.operation);
    }

    final impactId = _normalize(impact.entityId);
    final impactLabel = _normalize(impact.entityLabel);
    final relation = _normalize(impact.relation);
    for (final target in eligible) {
      final id = _normalize(target.entityId);
      final label = _normalize(target.entityLabel);
      if (id.isNotEmpty && (impactId == id || relation.contains(id))) {
        return true;
      }
      if (label.isNotEmpty &&
          (impactLabel == label ||
              relation.contains(label) ||
              _containsName(impact.entityLabel, target.entityLabel))) {
        return true;
      }
    }
    return false;
  }

  static EcosystemAgent? _currentAgent(
    EcosystemSnapshot snapshot,
    AgentRuntimeRequest request,
  ) {
    for (final agent in snapshot.agents) {
      if (agent.id == request.agentId) return agent;
    }
    final requestName = _normalize(request.agentName);
    if (requestName.isEmpty) return null;
    for (final agent in snapshot.agents) {
      if (_normalize(agent.name) == requestName) return agent;
    }
    return null;
  }

  static _EntityMatch _matchEntity({
    required String entityType,
    required String entityId,
    required String entityLabel,
    required EcosystemSnapshot snapshot,
  }) {
    final candidates = _entities(snapshot, entityType);
    final normalizedId = _normalize(entityId);
    final normalizedLabel = _normalize(entityLabel);

    for (final candidate in candidates) {
      if (normalizedId.isNotEmpty && _normalize(candidate.id) == normalizedId) {
        return candidate;
      }
    }
    for (final candidate in candidates) {
      if (normalizedLabel.isNotEmpty &&
          _normalize(candidate.label) == normalizedLabel) {
        return candidate;
      }
    }
    return _EntityMatch(
      entityType: entityType,
      id: entityId,
      label: entityLabel,
    );
  }

  static List<_EntityMatch> _entityMentionsForSubgoal(
    Subgoal subgoal,
    EcosystemSnapshot snapshot,
  ) {
    final text = [
      subgoal.label,
      for (final value in subgoal.requiredSlots.values) value?.toString() ?? '',
    ].join(' ');
    final all = <_EntityMatch>[
      ..._entities(snapshot, 'agent'),
      ..._entities(snapshot, 'workflow'),
      ..._entities(snapshot, 'provider'),
      ..._entities(snapshot, 'module'),
    ];
    return [
      for (final entity in all)
        if (_containsName(text, entity.label)) entity,
    ];
  }

  static List<_EntityMatch> _entities(
    EcosystemSnapshot snapshot,
    String entityType,
  ) {
    switch (entityType) {
      case 'agent':
        return [
          for (final agent in snapshot.agents)
            _EntityMatch(
              entityType: 'agent',
              id: agent.id,
              label: agent.name,
              metadata: {
                'provider': agent.providerNickname,
                'provider_nickname': agent.providerNickname,
                'used_by_workflows': agent.usedByWorkflows,
              },
            ),
        ];
      case 'workflow':
        return [
          for (final workflow in snapshot.workflows)
            _EntityMatch(
              entityType: 'workflow',
              id: workflow.id,
              label: workflow.title,
              metadata: {
                'agent': workflow.agentName,
                'agent_name': workflow.agentName,
                'agent_id': workflow.agentId,
                'trigger': workflow.triggerSummary,
                'enabled': workflow.enabled,
              },
            ),
        ];
      case 'provider':
        return [
          for (final provider in snapshot.providers)
            _EntityMatch(
              entityType: 'provider',
              id: provider.id,
              label: provider.nickname,
              metadata: {'nickname': provider.nickname},
            ),
        ];
      case 'module':
        return [
          for (final module in snapshot.modules)
            _EntityMatch(
              entityType: 'module',
              id: module.id,
              label: module.id,
              metadata: {'enabled': module.enabled},
            ),
        ];
      default:
        return const [];
    }
  }

  static bool _requiresSnapshotTarget(String entityType, String operation) {
    if (!_isSnapshotBackedEntity(entityType)) return false;
    switch (operation) {
      case 'delete':
      case 'update':
      case 'rename':
      case 'toggle':
      case 'read':
      case 'get':
        return true;
      default:
        return false;
    }
  }

  static String _entityTypeForSeed(ReflectionTarget seed) {
    final evidence = [
      seed.entityId,
      seed.entityLabel,
      for (final value in seed.selector.values) value?.toString() ?? '',
    ];
    if (_urlLikeValue(evidence) != null) return 'url';
    if (_pathLikeValue(evidence) != null) return 'file';
    if (_packageLikeValue(evidence) != null) return 'app';
    final raw = _normalize(seed.entityType);
    if (raw == 'file_path' || raw == 'path') return 'file';
    if (raw == 'package' || raw == 'app_package') return 'app';
    return raw;
  }

  static String _operationForSeed(ReflectionTarget seed, String entityType) {
    final raw = _normalize(seed.operation);
    if (raw.isNotEmpty) return raw;
    if (entityType == 'file' || entityType == 'url' || entityType == 'app') {
      return _inferReadOnlyOperation(seed.entityLabel);
    }
    return 'unknown';
  }

  static bool _isReadOnlyOperation(String operation) {
    switch (_normalize(operation)) {
      case 'read':
      case 'get':
      case 'list':
      case 'open':
      case 'search':
      case 'resolve':
      case 'summarize':
      case 'classify':
      case 'preview':
        return true;
      default:
        return false;
    }
  }

  static bool _isSnapshotBackedEntity(String entityType) {
    switch (entityType) {
      case 'agent':
      case 'workflow':
      case 'provider':
      case 'module':
        return true;
      default:
        return false;
    }
  }

  static String _slotString(Subgoal subgoal, List<String> keys) {
    for (final key in keys) {
      final value = subgoal.requiredSlots[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return '';
  }

  static String _targetKey(ReflectionTarget target, int index) {
    if (target.subgoalId.isNotEmpty) return target.subgoalId;
    if (target.entityId.isNotEmpty) return target.entityId;
    if (target.entityLabel.isNotEmpty) return target.entityLabel;
    return 'target_${index + 1}';
  }

  static String _normalize(String value) => value.trim().toLowerCase();

  static String _inferReadOnlyOperation(String text) {
    final normalized = _normalize(text);
    if (normalized.contains('search') || normalized.contains('cari')) {
      return 'search';
    }
    if (normalized.contains('open') || normalized.contains('buka')) {
      return 'open';
    }
    if (normalized.contains('list') || normalized.contains('daftar')) {
      return 'list';
    }
    return 'read';
  }

  static String? _urlLikeValue(Iterable<String> values) {
    for (final value in values) {
      final trimmed = value.trim();
      final lower = trimmed.toLowerCase();
      if (lower.startsWith('http://') ||
          lower.startsWith('https://') ||
          lower.startsWith('mailto:')) {
        return trimmed;
      }
    }
    return null;
  }

  static String? _pathLikeValue(Iterable<String> values) {
    for (final value in values) {
      final url = _urlLikeValue([value]);
      if (url != null) continue;
      final normalized = value.trim().replaceAll('\\', '/');
      if (normalized.isEmpty) continue;
      final tokens = normalized
          .split(RegExp(r'[\s,;]+'))
          .map((token) => _stripEdgeQuotes(token.trim()))
          .where((token) => token.isNotEmpty);
      for (final token in tokens) {
        final lower = token.toLowerCase();
        if (lower.startsWith('agents/') ||
            lower.startsWith('notes/') ||
            lower.startsWith('workflows/') ||
            lower.startsWith('files/') ||
            lower.contains('/') && _hasFileExtension(lower) ||
            _hasFileExtension(lower)) {
          return token;
        }
      }
    }
    return null;
  }

  static String? _packageLikeValue(Iterable<String> values) {
    final packagePattern = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,}$');
    for (final value in values) {
      final trimmed = value.trim().toLowerCase();
      if (packagePattern.hasMatch(trimmed)) return value.trim();
    }
    return null;
  }

  static bool _hasFileExtension(String value) {
    return RegExp(
      r'\.(md|txt|json|yaml|yml|csv|pdf|docx?|xlsx?|png|jpe?g|webp)$',
      caseSensitive: false,
    ).hasMatch(value);
  }

  static String _stripEdgeQuotes(String value) {
    var out = value;
    while (out.length >= 2 &&
        ((out.startsWith('"') && out.endsWith('"')) ||
            (out.startsWith("'") && out.endsWith("'")))) {
      out = out.substring(1, out.length - 1).trim();
    }
    return out;
  }

  static bool _containsName(String text, String name) {
    final normalizedText = _normalize(text);
    final normalizedName = _normalize(name);
    if (normalizedText.isEmpty || normalizedName.isEmpty) return false;
    if (RegExp(r'[^\x00-\x7F]').hasMatch(normalizedName)) {
      return normalizedText.contains(normalizedName);
    }
    if (normalizedName.contains(' ')) {
      return normalizedText.contains(normalizedName);
    }
    final tokens = normalizedText
        .split(RegExp(r'[^a-z0-9_]+', caseSensitive: false))
        .where((token) => token.isNotEmpty);
    return tokens.contains(normalizedName);
  }

  static String _clarifyForBlocking(
    List<ResolvedTarget> targets,
    DetectedLanguage language,
  ) {
    final names = targets
        .map((t) => t.entityLabel.isNotEmpty ? t.entityLabel : t.key)
        .where((name) => name.trim().isNotEmpty)
        .toSet()
        .join(', ');
    if (names.isEmpty) {
      return LanguageRegistry.phrase('clarify_target_unknown', language.code);
    }
    return LanguageRegistry.phrase('clarify_target_unverified', language.code, {
      'names': names,
    });
  }

  static String _blockForNoEligibleTargets(
    List<ResolvedTarget> targets,
    DetectedLanguage language,
  ) {
    final names = targets
        .map((t) => t.entityLabel.isNotEmpty ? t.entityLabel : t.key)
        .where((name) => name.trim().isNotEmpty)
        .toSet()
        .join(', ');
    if (names.isEmpty) {
      return LanguageRegistry.phrase('block_no_targets', language.code);
    }
    return LanguageRegistry.phrase(
      'clarify_target_no_eligible',
      language.code,
      {'names': names},
    );
  }
}

class _EntityMatch {
  const _EntityMatch({
    required this.entityType,
    required this.id,
    required this.label,
    this.metadata = const {},
  });

  final String entityType;
  final String id;
  final String label;

  /// Per-entity-type extended fields for predicate matching.
  ///
  /// Populated at snapshot-read time so `_matchesPredicate` can generically
  /// resolve `selector.field` without a per-entity-type switch. Examples:
  /// - workflow: {agent, agent_name, agent_id, trigger, enabled}
  /// - agent:    {provider, provider_nickname}
  /// - module:   {enabled}
  /// - provider: {nickname}
  final Map<String, dynamic> metadata;
}

class _BulkExpansion {
  const _BulkExpansion({
    required this.originSubgoalId,
    required this.targets,
    required this.subgoals,
  });

  final String originSubgoalId;
  final List<ReflectionTarget> targets;
  final List<Subgoal> subgoals;
}
