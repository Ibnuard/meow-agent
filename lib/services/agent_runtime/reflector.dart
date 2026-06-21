import 'package:dio/dio.dart';

import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'ecosystem_snapshot.dart';
import 'goal_tree.dart';
import 'json_utils.dart';
import 'language_detector.dart';
import 'prompt_constants.dart';
import 'runtime_logger.dart';
import 'runtime_models.dart';

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

/// The mandatory deep-thinking phase between analyze and execute.
///
/// Per the v2 design doc (§3.2 + §4.2): every non-trivial run goes through
/// reflection. The reflector decides:
/// 1. Goal tree shape (already partially seeded by the analyzer)
/// 2. Required slots vs missing slots — drives `clarify` strategy
/// 3. Ecosystem impacts — drives `autoResolve` / `block`
/// 4. Strategy selection
///
/// Failures degrade to `directExecute` with the analyzer's seed tree, so a
/// reflection outage never bricks the runtime.
class Reflector {
  Reflector({required this.client, required this.config, this.cancelToken});

  final OpenAiCompatibleClient client;
  final LlmProviderConfig config;
  final CancelToken? cancelToken;

  /// Maximum LLM retries before degrading to directExecute. Per user spec.
  static const int maxRetries = 2;

  Future<ReflectionOutput> reflect({
    required String userMessage,
    required Map<String, dynamic> analysis,
    required EcosystemSnapshot snapshot,
    required List<ToolDefinition> availableTools,
    required DetectedLanguage language,
    required RuntimeLogger logger,
    List<Map<String, String>> recentMessages = const [],
    String agentName = '',
    String agentId = '',
  }) async {
    final analyzerSeedTree = _seedTreeFromAnalysis(analysis, userMessage);

    // Don't bother reflecting on trivial chat — empty tree, no slots, no risk.
    final intent = (analysis['intent'] ?? '').toString();
    final requiresTools = analysis['requires_tools'] as bool? ?? false;
    if (!requiresTools && intent.isEmpty) {
      return ReflectionOutput(
        strategy: ReflectionStrategy.directExecute,
        goalTree: analyzerSeedTree,
        reasoning: 'No tools required; skipping reflection.',
      );
    }

    final prompt = _buildPrompt(
      userMessage: userMessage,
      analysis: analysis,
      snapshot: snapshot,
      availableTools: availableTools,
      language: language,
      recentMessages: recentMessages,
      agentName: agentName,
      agentId: agentId,
    );

    Map<String, dynamic>? parsed;
    var attempts = 0;
    String lastResponse = '';
    while (attempts < maxRetries && parsed == null) {
      try {
        final response = await client.chat(
          config: config,
          phase: attempts == 0 ? 'reflect' : 'reflect.repair',
          cancelToken: cancelToken,
          messages: [
            {'role': 'system', 'content': PromptConstants.jsonOnlySystem},
            {
              'role': 'user',
              'content': attempts == 0
                  ? prompt
                  : '${PromptConstants.jsonRepairIntro}\n\n$lastResponse',
            },
          ],
        );
        lastResponse = response;
        parsed = JsonUtils.tryParseObject(response);
      } catch (e) {
        logger.logError(
          'Reflection LLM call failed (attempt ${attempts + 1})',
          e,
        );
      }
      attempts++;
    }

    if (parsed == null) {
      logger.logError(
        'Reflection failed after $attempts attempts; degrading to direct execute',
      );
      return ReflectionOutput(
        strategy: ReflectionStrategy.directExecute,
        goalTree: analyzerSeedTree,
        reasoning: 'Reflector failed; degraded to direct execute.',
        degraded: true,
      );
    }

    return _parseOutput(parsed, fallbackTree: analyzerSeedTree);
  }

  // ─── Prompt builder ────────────────────────────────────────────────────────

  String _buildPrompt({
    required String userMessage,
    required Map<String, dynamic> analysis,
    required EcosystemSnapshot snapshot,
    required List<ToolDefinition> availableTools,
    required DetectedLanguage language,
    required List<Map<String, String>> recentMessages,
    String agentName = '',
    String agentId = '',
  }) {
    final selfIdentityBlock = agentName.isEmpty
        ? ''
        : '\n${PromptConstants.selfIdentity(agentName: agentName, agentId: agentId)}\n';
    final historyBlock = recentMessages.isEmpty
        ? 'No prior conversation.'
        : recentMessages.map((m) => '${m['role']}: ${m['content']}').join('\n');

    final ecosystemBlock = snapshot.isRelevantForReflection
        ? snapshot.toCompactString()
        : 'ECOSYSTEM SNAPSHOT: omitted (not relevant for this turn).';

    final toolsBlock = availableTools.isEmpty
        ? 'No tools available.'
        : availableTools
              .map(
                (t) =>
                    '- ${t.name} (${t.risk}): ${t.description}'
                    '${t.inputSchema.isEmpty ? '' : ' · args: ${_schemaSummary(t.inputSchema)}'}',
              )
              .join('\n');

    // Recovery context: when the runtime is asking the reflector to rethink
    // after a previous failure, surface the full attempt history. This is
    // what makes "never give up" actually work — without it, the LLM has no
    // memory of what already failed and would just retry the same approach.
    final priorAttempts = analysis['prior_attempts'];
    String? priorAttemptsBlock;
    if (priorAttempts is List && priorAttempts.isNotEmpty) {
      final lines = <String>[];
      for (var i = 0; i < priorAttempts.length; i++) {
        final entry = priorAttempts[i];
        if (entry is Map) {
          final reason = (entry['reason'] ?? 'unknown').toString();
          final tool = (entry['tool'] ?? entry['failed_tool'] ?? '').toString();
          final args = (entry['args'] ?? entry['failed_args'] ?? '').toString();
          final entity = (entry['unverified_entity'] ?? '').toString();
          final detail = [
            if (tool.isNotEmpty) 'tool=$tool',
            if (args.isNotEmpty) 'args=$args',
            if (entity.isNotEmpty) 'unverified=$entity',
          ].join(', ');
          lines.add(
            '  ${i + 1}. reason=$reason${detail.isEmpty ? '' : ' · $detail'}',
          );
        }
      }
      if (lines.isNotEmpty) {
        priorAttemptsBlock =
            'PRIOR ATTEMPTS (these already failed — DO NOT repeat them; '
            'pick a fundamentally different approach):\n${lines.join('\n')}';
      }
    }

    final broadenedNote = analysis['available_tools_broadened'] == true
        ? 'NOTE: The full tool catalog is now available. Consider tools '
              'outside the original selection if they fit better.'
        : '';

    return '''${PromptConstants.reflectIntro}

${PromptConstants.policyMinimal}
$selfIdentityBlock
${PromptConstants.reflectRules(language.label)}

SELF-TARGET BINDING (CRITICAL — prevents focusing on the wrong agent):
- When the user's CURRENT message refers to THIS agent with a first/second-person reference ("you", "your personality", "this agent", "yourself") and the operation is a READ (read/get/list a persona/config/identity), emit the target with entity_type="agent", operation="read", and entity_label="current_agent". The runtime binds that to the active agent.
- Do NOT copy an agent name that appeared only in EARLIER turns (e.g. an agent the user listed or deleted before) into the current target. The current user message is authoritative for who the target is.
- Only emit a DIFFERENT agent's name as the target when the user names that agent in the CURRENT message.

CRITICAL — ANALYZER DECISION BINDING:
- The analyzer has ALREADY classified this request: requires_tools=${analysis['requires_tools']}, intent="${analysis['intent']}", goal="${analysis['goal']}".
- If requires_tools=true and subgoal_seeds are present, the request IS an action request — DO NOT downgrade it to a casual greeting or chat response.
- Recent friendly conversation tone (greetings, small talk) does NOT override the analyzer's classification. Treat the analyzer's intent as authoritative for strategy selection.
- If requires_tools=true, use direct_execute or auto_resolve — NEVER clarify/block just because the tone is friendly.
- Your goal_tree main_goal MUST reflect the analyzer's goal, not the conversation tone.

User message: "$userMessage"

Analyzer output:
${_jsonSummary(analysis)}
${priorAttemptsBlock == null ? '' : '\n$priorAttemptsBlock\n'}${broadenedNote.isEmpty ? '' : '\n$broadenedNote\n'}
Recent conversation:
$historyBlock

$ecosystemBlock

Available tools:
$toolsBlock

${PromptConstants.reflectResponseFormat}''';
  }

  String _schemaSummary(Map<String, String> schema) {
    final entries = schema.entries.take(8).map((e) => '${e.key}:${e.value}');
    return entries.join(', ');
  }

  String _jsonSummary(Map<String, dynamic> json) {
    final keep = [
      'intent',
      'goal',
      'requires_tools',
      'risk',
      'missing_info',
      'subgoal_seeds',
    ];
    final compact = <String, dynamic>{};
    for (final k in keep) {
      if (json.containsKey(k)) compact[k] = json[k];
    }
    return compact.entries.map((e) => '  ${e.key}: ${e.value}').join('\n');
  }

  // ─── Output parser ─────────────────────────────────────────────────────────

  ReflectionOutput _parseOutput(
    Map<String, dynamic> json, {
    required GoalTree fallbackTree,
  }) {
    final strategy = ReflectionStrategyX.fromLabel(json['strategy'] as String?);

    final treeJson = json['goal_tree'] as Map<String, dynamic>?;
    final goalTree = treeJson != null
        ? GoalTree.fromJson(treeJson)
        : fallbackTree;

    final impactsJson = json['impacts'] as List?;
    final impacts = impactsJson == null
        ? const <ReflectionImpact>[]
        : impactsJson
              .whereType<Map>()
              .map((m) => ReflectionImpact.fromJson(m.cast<String, dynamic>()))
              .toList(growable: false);

    final targetsJson = json['targets'] as List?;
    final targets = targetsJson == null
        ? const <ReflectionTarget>[]
        : targetsJson
              .whereType<Map>()
              .map((m) => ReflectionTarget.fromJson(m.cast<String, dynamic>()))
              .toList(growable: false);

    final clarifyQuestionsJson = json['clarify_questions'] as List?;
    final clarifyQuestions = clarifyQuestionsJson == null
        ? const <String>[]
        : clarifyQuestionsJson.map((e) => e.toString()).toList();

    final blockReason = (json['block_reason'] ?? '').toString();
    final reasoning = (json['reasoning'] ?? '').toString();
    final narrative = (json['narrative'] ?? '').toString();
    final nextNarrative = (json['next_narrative'] ?? '').toString();

    return ReflectionOutput(
      strategy: strategy,
      goalTree: goalTree,
      targets: targets,
      impacts: impacts,
      clarifyQuestions: clarifyQuestions,
      blockReason: blockReason,
      reasoning: reasoning,
      narrative: narrative,
      nextNarrative: nextNarrative,
    );
  }

  // ─── Fallback seed tree from analyzer ──────────────────────────────────────

  GoalTree _seedTreeFromAnalysis(
    Map<String, dynamic> analysis,
    String userMessage,
  ) {
    final mainGoal = (analysis['goal'] as String?) ?? userMessage;
    final seeds = analysis['subgoal_seeds'];
    if (seeds is List && seeds.isNotEmpty) {
      return GoalTree(
        mainGoal: mainGoal,
        subgoals: [
          for (var i = 0; i < seeds.length; i++)
            Subgoal(id: 'sg${i + 1}', label: seeds[i].toString()),
        ],
      );
    }
    return GoalTree.singleSubgoal(mainGoal: mainGoal, subgoalLabel: mainGoal);
  }
}
