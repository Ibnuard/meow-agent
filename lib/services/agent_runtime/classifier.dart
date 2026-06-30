import 'package:dio/dio.dart';

import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'ecosystem_snapshot.dart';
import 'goal_tree.dart';
import 'language_detector.dart';
import 'llm_json_caller.dart';
import 'pending_action.dart';
import 'predefined_skills/predefined_skills.dart';
import 'prompt_classify.dart';
import 'prompt_constants.dart';
import 'reflector.dart';
import 'runtime_logger.dart';
import 'runtime_models.dart';

/// Unified output of the merged classify call.
///
/// Replaces the separate [analysis] Map + [ReflectionOutput] + [plan] Map
/// that were previously produced by three independent LLM round-trips.
/// The runtime engine reads from this single object to drive all downstream
/// deterministic logic (tool narrowing, target resolution, execute loop).
class ClassifyResult {
  ClassifyResult({
    required this.raw,
    required this.analysis,
    required this.reflection,
    required this.plan,
    required this.degraded,
  });

  /// The full parsed JSON from the LLM. Kept for forward-compat with any
  /// engine code that reads ad-hoc fields from the old analysis Map.
  final Map<String, dynamic> raw;

  /// Analysis-level fields (intent, goal, requires_tools, missing_info,
  /// selected_skill_ids, task_relation, etc.).
  final Map<String, dynamic> analysis;

  /// Reflection-level fields (strategy, targets, impacts, clarify_questions,
  /// block_reason).
  final ReflectionOutput reflection;

  /// Plan-level fields (main_goal, completion_criteria, subgoals with slots).
  final Map<String, dynamic> plan;

  /// True when the LLM call failed and we degraded to a fallback.
  final bool degraded;

  bool get isChatRoute => raw['route'] == 'chat';
  String get directResponse => (raw['direct_response'] ?? '').toString().trim();
  String get detectedLanguage =>
      (raw['detected_language'] ?? '').toString().trim().toLowerCase();

  List<String> get requiredCapabilities {
    final caps = raw['required_capabilities'];
    if (caps is List) {
      return caps.map((e) => e.toString()).toList();
    }
    return const [];
  }
}

/// Merges analyze + reflect + plan into a single LLM call (L3 optimization).
///
/// Before: 3 separate LLM round-trips (analyze → reflect → plan), each
/// re-deriving intent and losing context between phases.
/// After: 1 LLM call that produces routing, intent, strategy, targets, and
/// goal tree in one pass — no cross-phase drift.
///
/// The runtime engine replaces the 3-phase sequence with:
///   final result = await classifier.classify(...);
///   if (result.isChatRoute) return result.directResponse;
///   // ... deterministic post-processing (tool narrowing, target resolution)
///   // ... execute loop with result.plan + result.reflection.goalTree
class Classifier {
  Classifier({
    required this.client,
    required this.config,
    this.cancelToken,
  });

  final OpenAiCompatibleClient client;
  final LlmProviderConfig config;
  final CancelToken? cancelToken;

  Future<ClassifyResult> classify({
    required String userMessage,
    required AgentWorkspace workspace,
    required EcosystemSnapshot snapshot,
    required List<ToolDefinition> availableTools,
    required DetectedLanguage language,
    required RuntimeLogger logger,
    required String stableContext,
    List<Map<String, String>> recentMessages = const [],
    PendingAction? pendingAction,
    String recentToolMemory = '',
    bool isWorkflowAutoExecute = false,
    String activeTaskContext = '',
    String agentName = '',
    String agentId = '',
    List<String> resolvedTargetLabels = const [],
    bool userNotIntroduced = false,
  }) async {
    final prompt = buildPrompt(
      userMessage: userMessage,
      workspace: workspace,
      snapshot: snapshot,
      availableTools: availableTools,
      language: language,
      recentMessages: recentMessages,
      pendingAction: pendingAction,
      recentToolMemory: recentToolMemory,
      isWorkflowAutoExecute: isWorkflowAutoExecute,
      activeTaskContext: activeTaskContext,
      agentName: agentName,
      agentId: agentId,
      resolvedTargetLabels: resolvedTargetLabels,
      userNotIntroduced: userNotIntroduced,
    );

    final caller = LlmJsonCaller(
      client: client,
      config: config,
      cancelToken: cancelToken,
    );

    final parsed = await caller.call(
      prompt,
      'classify',
      logger,
      stableContext: stableContext,
    );

    if (parsed == null) {
      logger.logError(
        'Classify failed after LlmJsonCaller attempts; retrying with simplified schema',
      );
      // The full merged schema is large and weak models frequently emit
      // malformed JSON for complex multi-step tasks. Retry ONCE with a
      // minimal schema that requests only route/goal/subgoals — tiny enough
      // that weak models reliably produce valid JSON. This recovers the
      // multi-step plan structure instead of collapsing to a single subgoal
      // (which would starve complex tasks of execute-loop budget).
      final simplified = await _retrySimplifiedClassify(
        userMessage: userMessage,
        logger: logger,
        stableContext: stableContext,
        activeTaskContext: activeTaskContext,
      );
      if (simplified != null) {
        logger.logLlmDecision(
          'classify.simplified',
          simplified.raw,
          version: PromptConstants.promptVersion,
        );
        return simplified;
      }
      logger.logError(
        'Simplified classify retry also failed; degrading to direct execute',
      );
      return _degradedResult(userMessage, activeTaskContext: activeTaskContext);
    }

    return _parseResult(parsed, userMessage);
  }

  /// One-shot retry with a minimal JSON schema when the full classify failed
  /// to parse. Returns a [ClassifyResult] built from the simplified fields, or
  /// null if this retry also fails to parse.
  Future<ClassifyResult?> _retrySimplifiedClassify({
    required String userMessage,
    required RuntimeLogger logger,
    required String stableContext,
    String activeTaskContext = '',
  }) async {
    final prompt = PromptConstants.classifySimplifiedFallback(
      userMessage: userMessage,
      activeTaskContext: activeTaskContext,
    );
    final simplifiedCaller = LlmJsonCaller(
      client: client,
      config: config,
      cancelToken: cancelToken,
    );
    final parsed = await simplifiedCaller.call(
      prompt,
      'classify.simplified',
      logger,
      stableContext: stableContext,
    );
    if (parsed == null) return null;
    return _parseSimplifiedResult(parsed, userMessage);
  }

  /// Build a full [ClassifyResult] from the minimal simplified schema.
  /// Fills the analysis/reflection/plan maps the engine expects, deriving the
  /// goal tree from the simplified `subgoals` array so multi-step structure
  /// survives the fallback.
  ClassifyResult _parseSimplifiedResult(
    Map<String, dynamic> json,
    String userMessage,
  ) {
    final route = (json['route'] ?? 'agentic').toString();
    final isChat = route == 'chat';
    final directResponse = (json['direct_response'] ?? '').toString().trim();
    final goal = (json['goal'] ?? json['main_goal'] ?? userMessage).toString();
    final requiresTools = json['requires_tools'] ?? !isChat;
    final detectedLanguage =
        (json['detected_language'] ?? '').toString().trim().toLowerCase();
    final taskRelation = (json['task_relation'] ?? 'none').toString();
    final mainGoal = (json['main_goal'] ?? goal).toString();
    final subgoalsJson = json['subgoals'] as List?;

    final analysis = <String, dynamic>{
      'intent': '',
      'goal': goal,
      'requires_tools': requiresTools,
      'risk': 'safe',
      'detected_language': detectedLanguage,
      'selected_skill_ids': const [],
      'tool_groups': const [],
      'missing_info': const [],
      'subgoal_seeds': const [],
      'task_relation': taskRelation,
      'direct_response': isChat ? directResponse : '',
      'narrative': '',
      'next_narrative': '',
      'route': route,
      'required_capabilities': const [],
    };

    final goalTree = (subgoalsJson == null || subgoalsJson.isEmpty)
        ? GoalTree.singleSubgoal(mainGoal: mainGoal, subgoalLabel: mainGoal)
        : GoalTree.fromJson({
            'main_goal': mainGoal,
            'completion_criteria': const [],
            'subgoals': subgoalsJson,
          });

    final reflection = ReflectionOutput(
      strategy: ReflectionStrategy.directExecute,
      goalTree: goalTree,
      reasoning:
          'Classify parsed via simplified fallback schema; plan structure preserved.',
      degraded: true,
    );

    final plan = <String, dynamic>{
      'main_goal': mainGoal,
      'completion_criteria': const [],
      'subgoals': subgoalsJson ?? const [],
      'narrative': '',
      'next_narrative': '',
    };

    return ClassifyResult(
      raw: json,
      analysis: analysis,
      reflection: reflection,
      plan: plan,
      degraded: true,
    );
  }

  // ─── Prompt builder ────────────────────────────────────────────────────────

  static String buildPrompt({
    required String userMessage,
    required AgentWorkspace workspace,
    required EcosystemSnapshot snapshot,
    required List<ToolDefinition> availableTools,
    required DetectedLanguage language,
    required List<Map<String, String>> recentMessages,
    PendingAction? pendingAction,
    String recentToolMemory = '',
    bool isWorkflowAutoExecute = false,
    String activeTaskContext = '',
    String agentName = '',
    String agentId = '',
    List<String> resolvedTargetLabels = const [],
    bool userNotIntroduced = false,
  }) {
    final languageLabel = language.label;
    final historyBlock = recentMessages.isNotEmpty
        ? recentMessages.map((m) => '${m['role']}: ${m['content']}').join('\n')
        : 'No prior conversation.';

    final pendingBlock = pendingAction != null
        ? '\nPENDING ACTION (user was previously asked to confirm this):\n'
              'Tool: ${pendingAction.toolName}\n'
              'Args: ${pendingAction.toolArgs}\n'
              'Summary: ${pendingAction.userFacingSummary}\n\n'
              'If the user asks for a different action instead of confirming/rejecting/previewing this pending action, set task_relation="new_task" and analyze the new request on its own.'
        : '';

    final memoryBlock = recentToolMemory.isNotEmpty
        ? '\n\n${PromptConstants.memoryHeader}\n$recentToolMemory\n\n'
              '${PromptConstants.memoryInstructions}'
        : '';

    final sourceModeBlock = isWorkflowAutoExecute
        ? '\n\nWORKFLOW EXECUTION MODE:\n'
              '- This run is a scheduled workflow. There is no user available for real-time interaction.\n'
              '- The user pre-approved sensitive actions when creating this workflow.\n'
              '- ALWAYS set requires_tools=true if the prompt describes an action.\n'
              '- NEVER set requires_tools=false to ask for permission — execute directly.\n'
        : '';

    // Introduction/bootstrap rule: when the user hasn't introduced themselves
    // yet (no name in soul), inject the merged introduction gate so the
    // classifier knows to set route=chat and handle the intro naturally.
    // Only for interactive chat — workflows run unattended.
    final bootstrapBlock = (userNotIntroduced && !isWorkflowAutoExecute)
        ? '\n\n${PromptConstants.introductionGateRule}'
        : '';

    final activeTaskBlock = activeTaskContext.isNotEmpty
        ? '\n\nACTIVE TASK CONTEXT (a task is already in flight for this agent):\n'
              '$activeTaskContext\n\n'
              'Use this context to set task_relation before anything else.\n'
              'If the new user message is a standalone request or unrelated action, set task_relation="new_task".\n'
              'If it edits or refines the same goal, set task_relation="revision".\n'
              'If it just answers a clarify/affirms ("ok", "yes", "lanjut"), set task_relation="continuation".'
        : '';

    final ecosystemBlock = snapshot.isRelevantForReflection
        ? snapshot.toCompactString()
        : 'ECOSYSTEM SNAPSHOT: omitted (not relevant for this turn).';

    final toolsBlock = availableTools.isEmpty
        ? 'No tools available.'
        : availableTools
              .map((t) =>
                  '- ${t.name} (${t.risk}): ${t.description}'
                  '${t.inputSchema.isEmpty ? '' : ' · args: ${_schemaSummary(t.inputSchema)}'}')
              .join('\n');

    // Conditional mini-app code-gen policy — only when miniapp tools are in
    // the available set. Saves ~800 tokens for non-miniapp tasks.
    final toolNames = availableTools.map((t) => t.name).toList();
    final miniAppBlock =
        PromptConstants.toolsIncludeMiniApp(toolNames)
        ? '\n${PromptConstants.miniAppRules}\n'
        : '';

    final selectedSkillDetail = PredefinedSkillRegistry.skillDetailBlock(
      const [],
    );
    final skillBlock = selectedSkillDetail.isEmpty
        ? ''
        : '\nSelected skill context:\n$selectedSkillDetail\n';

    final predefinedSkillsBlock =
        PredefinedSkillRegistry.analyzerIndexBlock().isEmpty
        ? ''
        : '\nPredefined skill index:\n${PredefinedSkillRegistry.analyzerIndexBlock()}\n';

    final resolvedBlock = resolvedTargetLabels.isEmpty
        ? ''
        : '\nResolved targets (snapshot-matched, authoritative):\n'
              '${resolvedTargetLabels.map((l) => '- $l').join('\n')}\n'
              'Emit ONE subgoal per resolved target above. Use these labels verbatim.\n';

    return '''$promptClassifyIntro

${PromptConstants.systemRules(languageLabel, isWorkflowAutoExecute: isWorkflowAutoExecute)}
$predefinedSkillsBlock

$ecosystemBlock

Available tools:
$toolsBlock
$skillBlock$resolvedBlock$miniAppBlock

Recent conversation:
$historyBlock
$pendingBlock$memoryBlock$sourceModeBlock$bootstrapBlock$activeTaskBlock

User message: "$userMessage"

${PromptConstants.policyAsk}

${PromptConstants.profilePersistenceRules}

$promptClassifyRouteRules

$promptClassifyAnalyzeRules

$promptClassifyReflectRules

$promptClassifyPlanRules

$promptClassifyResponseFormat''';
  }

  static String _schemaSummary(Map<String, String> schema) {
    final entries = schema.entries.take(8).map((e) => '${e.key}:${e.value}');
    return entries.join(', ');
  }

  // ─── Output parser ─────────────────────────────────────────────────────────

  ClassifyResult _parseResult(Map<String, dynamic> json, String userMessage) {
    // Extract analysis-level fields into a sub-map for backward compat with
    // engine code that reads analysis['intent'], analysis['requires_tools'], etc.
    final analysis = <String, dynamic>{
      'intent': json['intent'] ?? '',
      'goal': json['goal'] ?? userMessage,
      'requires_tools': json['requires_tools'] ?? false,
      'risk': json['risk'] ?? 'safe',
      'detected_language': json['detected_language'] ?? '',
      'selected_skill_ids': json['selected_skill_ids'] ?? const [],
      'tool_groups': json['tool_groups'] ?? const [],
      'missing_info': json['missing_info'] ?? const [],
      'subgoal_seeds': json['subgoal_seeds'] ?? const [],
      'requested_item_count': json['requested_item_count'],
      'bulk_selector': json['bulk_selector'] ?? false,
      'task_relation': json['task_relation'] ?? 'none',
      'direct_response': json['direct_response'] ?? '',
      'narrative': json['narrative'] ?? '',
      'next_narrative': json['next_narrative'] ?? '',
      'route': json['route'] ?? 'agentic',
      'required_capabilities': json['required_capabilities'] ?? const [],
    };

    // Build reflection output.
    final strategy = ReflectionStrategyX.fromLabel(
      json['strategy'] as String?,
    );

    final treeJson = json['goal_tree'] as Map<String, dynamic>?;
    final goalTree = treeJson != null
        ? GoalTree.fromJson(treeJson)
        : _goalTreeFromMerged(json, userMessage);

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

    final reflection = ReflectionOutput(
      strategy: strategy,
      goalTree: goalTree,
      targets: targets,
      impacts: impacts,
      clarifyQuestions: clarifyQuestions,
      blockReason: (json['block_reason'] ?? '').toString(),
      reasoning: (json['reasoning'] ?? '').toString(),
      narrative: (json['narrative'] ?? '').toString(),
      nextNarrative: (json['next_narrative'] ?? '').toString(),
    );

    // Build plan-level fields.
    final plan = <String, dynamic>{
      'main_goal': json['main_goal'] ?? json['goal'] ?? userMessage,
      'completion_criteria': json['completion_criteria'] ?? const [],
      'subgoals': json['subgoals'] ?? const [],
      'narrative': json['narrative'] ?? '',
      'next_narrative': json['next_narrative'] ?? '',
    };

    return ClassifyResult(
      raw: json,
      analysis: analysis,
      reflection: reflection,
      plan: plan,
      degraded: false,
    );
  }

  /// Build a goal tree from the merged JSON's subgoals array when the LLM
  /// didn't emit a separate goal_tree field.
  GoalTree _goalTreeFromMerged(Map<String, dynamic> json, String userMessage) {
    final mainGoal = (json['main_goal'] ?? json['goal'] ?? userMessage).toString();
    final subgoalsJson = json['subgoals'] as List?;
    if (subgoalsJson == null || subgoalsJson.isEmpty) {
      return GoalTree.singleSubgoal(
        mainGoal: mainGoal,
        subgoalLabel: mainGoal,
      );
    }
    return GoalTree.fromJson({
      'main_goal': mainGoal,
      'completion_criteria': json['completion_criteria'] ?? const [],
      'subgoals': subgoalsJson,
    });
  }

  ClassifyResult _degradedResult(
    String userMessage, {
    String activeTaskContext = '',
  }) {
    // When there is an active task (ledger) and classify fails, degrade to
    // continuation so the runtime re-enters the execute loop with the existing
    // plan. Without this, the runtime falls through to a chat-only response
    // that promises action but never calls any tools — killing the active task.
    final hasActiveTask = activeTaskContext.isNotEmpty;
    final fallbackTree = GoalTree.singleSubgoal(
      mainGoal: userMessage,
      subgoalLabel: userMessage,
    );
    return ClassifyResult(
      raw: {
        'route': 'agentic',
        'requires_tools': hasActiveTask,
      },
      analysis: {
        'intent': '',
        'goal': userMessage,
        'requires_tools': hasActiveTask,
        'detected_language': '',
        'selected_skill_ids': const [],
        'tool_groups': const [],
        'missing_info': const [],
        'subgoal_seeds': const [],
        'task_relation': hasActiveTask ? 'continuation' : 'none',
        'direct_response': '',
        'narrative': '',
        'next_narrative': '',
        'route': 'agentic',
        'required_capabilities': const [],
      },
      reflection: ReflectionOutput(
        strategy: ReflectionStrategy.directExecute,
        goalTree: fallbackTree,
        reasoning: hasActiveTask
            ? 'Classify failed; degraded to continuation of active task.'
            : 'Classify failed; degraded to direct execute.',
        degraded: true,
      ),
      plan: {
        'main_goal': userMessage,
        'completion_criteria': const [],
        'subgoals': const [],
      },
      degraded: true,
    );
  }
}
