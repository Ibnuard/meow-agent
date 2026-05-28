import 'ecosystem_snapshot.dart';
import 'goal_tree.dart';
import 'language_detector.dart';
import 'reflector.dart';
import 'runtime_models.dart';

enum ResolvedTargetStatus {
  eligible,
  skipped,
  missing,
  ambiguous,
  ineligible,
}

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
        status:
            ResolvedTargetStatusX.fromLabel(json['status'] as String?),
        reason: (json['reason'] ?? '').toString(),
        selector:
            (json['selector'] as Map?)?.cast<String, dynamic>() ?? const {},
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
  const TargetResolutionResult({
    required this.reflection,
    required this.graph,
  });

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
    final resolved = _resolveTargets(
      reflection: reflection,
      snapshot: snapshot,
      request: request,
    );
    if (resolved.isEmpty) {
      return TargetResolutionResult(
        reflection: reflection,
        graph: TargetResolutionGraph(
          targets: const [],
          originalImpactCount: reflection.impacts.length,
          filteredImpactCount: reflection.impacts.length,
        ),
      );
    }

    final filteredSubgoals = _filterSubgoals(
      reflection.goalTree.subgoals,
      resolved,
    );
    final filteredImpacts = _filterImpacts(reflection.impacts, resolved);
    final graph = TargetResolutionGraph(
      targets: resolved,
      originalImpactCount: reflection.impacts.length,
      filteredImpactCount: filteredImpacts.length,
    );

    var strategy = reflection.strategy;
    var clarifyQuestions = reflection.clarifyQuestions;
    var blockReason = reflection.blockReason;
    final hasMissingSlots =
        filteredSubgoals.any((s) => s.missingSlots.isNotEmpty);

    if (graph.hasBlocking) {
      strategy = ReflectionStrategy.clarify;
      clarifyQuestions = [
        _clarifyForBlocking(graph.blockingTargets, language),
      ];
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
      mainGoal: reflection.goalTree.mainGoal,
      completionCriteria: reflection.goalTree.completionCriteria,
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
          reflection.reasoning,
          if (graph.hasSkipped)
            'Runtime skipped ineligible targets before impact handling.',
          if (graph.filteredImpacts)
            'Runtime removed impacts that were not linked to eligible targets.',
        ].where((s) => s.trim().isNotEmpty).join(' '),
        narrative: reflection.narrative,
        degraded: reflection.degraded,
      ),
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
      final match = _matchEntity(
        entityType: entityType,
        entityId: seed.entityId,
        entityLabel: seed.entityLabel,
        snapshot: snapshot,
      );
      var resolved = ResolvedTarget(
        key: _targetKey(seed, i),
        subgoalId: seed.subgoalId.isEmpty ? 'sg${i + 1}' : seed.subgoalId,
        operation: operation.isEmpty ? 'unknown' : operation,
        entityType: entityType.isEmpty ? match.entityType : entityType,
        entityId: match.id,
        entityLabel: match.label.isNotEmpty ? match.label : seed.entityLabel,
        selector: seed.selector,
      );

      if (_requiresSnapshotTarget(entityType, operation) &&
          resolved.entityId.isEmpty) {
        resolved = resolved.copyWith(
          status: ResolvedTargetStatus.missing,
          reason: 'target_not_found',
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
        out.add(ReflectionTarget(
          subgoalId: subgoal.id,
          operation: operation.isEmpty ? 'read' : operation,
          entityType: entityType,
          entityId: '',
          entityLabel: pathLike,
        ));
        continue;
      }

      final matches = _entityMentionsForSubgoal(subgoal, snapshot);
      if (matches.isEmpty && (operation.isNotEmpty || entityType.isNotEmpty)) {
        out.add(ReflectionTarget(
          subgoalId: subgoal.id,
          operation: operation,
          entityType: entityType,
          entityId: entityId,
          entityLabel: label,
        ));
        continue;
      }
      for (final match in matches) {
        out.add(ReflectionTarget(
          subgoalId: subgoal.id,
          operation: operation,
          entityType: entityType.isNotEmpty ? entityType : match.entityType,
          entityId: entityId.isNotEmpty ? entityId : match.id,
          entityLabel: label.isNotEmpty ? label : match.label,
        ));
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
    return _EntityMatch(entityType: entityType, id: entityId, label: entityLabel);
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
            ),
        ];
      case 'workflow':
        return [
          for (final workflow in snapshot.workflows)
            _EntityMatch(
              entityType: 'workflow',
              id: workflow.id,
              label: workflow.title,
            ),
        ];
      case 'provider':
        return [
          for (final provider in snapshot.providers)
            _EntityMatch(
              entityType: 'provider',
              id: provider.id,
              label: provider.nickname,
            ),
        ];
      case 'module':
        return [
          for (final module in snapshot.modules)
            _EntityMatch(
              entityType: 'module',
              id: module.id,
              label: module.id,
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
    if (language.code == 'id') {
      return names.isEmpty
          ? 'Aku belum bisa memastikan target yang dimaksud. Target mana yang mau dipakai?'
          : 'Aku belum bisa memastikan target ini: $names. Mau pakai target yang mana?';
    }
    return names.isEmpty
        ? 'I cannot verify the requested target yet. Which target should I use?'
        : 'I cannot verify these target(s): $names. Which target should I use?';
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
    if (language.code == 'id') {
      return names.isEmpty
          ? 'Tidak ada target valid yang bisa aku kerjakan dari permintaan ini.'
          : 'Tidak ada target valid yang bisa aku kerjakan. Target yang dilewati: $names.';
    }
    return names.isEmpty
        ? 'There are no valid targets I can act on for this request.'
        : 'There are no valid targets I can act on. Skipped target(s): $names.';
  }
}

class _EntityMatch {
  const _EntityMatch({
    required this.entityType,
    required this.id,
    required this.label,
  });

  final String entityType;
  final String id;
  final String label;
}
