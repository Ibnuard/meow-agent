import 'package:dio/dio.dart';

import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'llm_json_caller.dart';
import 'pending_action.dart';
import 'predefined_skills/predefined_skills.dart';
import 'prompt_templates.dart';
import 'runtime_logger.dart';
import 'runtime_models.dart';

/// Analyzes user intent and creates an execution plan via LLM.
class Planner {
  Planner({
    required this.client,
    required this.config,
    required this.languageCode,
    this.cancelToken,
  });

  final OpenAiCompatibleClient client;
  final LlmProviderConfig config;
  final String languageCode;
  final CancelToken? cancelToken;

  LlmJsonCaller get _caller =>
      LlmJsonCaller(client: client, config: config, cancelToken: cancelToken);

  /// Fast ordinary-chat route. Returns parsed JSON or null on failure.
  Future<Map<String, dynamic>?> chatRoute({
    required String userMessage,
    required String soul,
    required String memory,
    required bool userNotIntroduced,
    required RuntimeLogger logger,
    List<Map<String, String>> recentMessages = const [],
    String agentName = '',
    String agentId = '',
    String? defaultLanguageCode,
  }) async {
    final prompt = PromptTemplates.chatRoutePrompt(
      userMessage: userMessage,
      languageCode: defaultLanguageCode ?? languageCode,
      soul: soul,
      memory: memory,
      userNotIntroduced: userNotIntroduced,
      recentMessages: recentMessages,
      agentName: agentName,
      agentId: agentId,
    );

    return _caller.call(prompt, 'chat_route', logger);
  }

  /// Analyze user intent. Returns parsed JSON or null on failure.
  Future<Map<String, dynamic>?> analyze({
    required String userMessage,
    required AgentWorkspace workspace,
    required List<String> availableTools,
    required RuntimeLogger logger,
    List<Map<String, String>> recentMessages = const [],
    PendingAction? pendingAction,
    String recentToolMemory = '',
    bool isWorkflowAutoExecute = false,
    String activeTaskContext = '',
    String agentName = '',
    String agentId = '',
  }) async {
    final prompt = PromptTemplates.analyzePrompt(
      userMessage: userMessage,
      workspace: workspace,
      availableTools: availableTools,
      languageCode: languageCode,
      recentMessages: recentMessages,
      pendingAction: pendingAction,
      recentToolMemory: recentToolMemory,
      isWorkflowAutoExecute: isWorkflowAutoExecute,
      activeTaskContext: activeTaskContext,
      agentName: agentName,
      agentId: agentId,
    );

    final stableContext = PromptTemplates.buildStableContext(
      soul: workspace.soul,
      skills: workspace.skills,
      agentName: agentName,
      agentId: agentId,
    );

    final result = await _caller.call(
      prompt,
      'analyze',
      logger,
      stableContext: stableContext,
    );
    _normalizeSelectedSkills(result);
    return result;
  }

  void _normalizeSelectedSkills(Map<String, dynamic>? analysis) {
    if (analysis == null) return;

    final rawSkillIds = analysis['selected_skill_ids'];
    final normalized = rawSkillIds is List
        ? PredefinedSkillRegistry.normalizeSkillIds(rawSkillIds)
        : <String>[];

    if (normalized.isNotEmpty) {
      analysis['selected_skill_ids'] = normalized;
      return;
    }

    final rawGroups = analysis['tool_groups'];
    analysis['selected_skill_ids'] = rawGroups is List
        ? PredefinedSkillRegistry.skillIdsForToolGroups(rawGroups)
        : <String>[];
  }

  /// Create execution plan from analysis. Returns parsed JSON or null.
  Future<Map<String, dynamic>?> plan({
    required Map<String, dynamic> analysis,
    required List<String> availableTools,
    required RuntimeLogger logger,
    List<String> resolvedTargetLabels = const [],
    String? stableContext,
  }) async {
    final prompt = PromptTemplates.planPrompt(
      analysis: analysis,
      availableTools: availableTools,
      resolvedTargetLabels: resolvedTargetLabels,
    );

    final result = await _caller.call(
      prompt,
      'plan',
      logger,
      stableContext: stableContext,
    );
    return result;
  }
}
