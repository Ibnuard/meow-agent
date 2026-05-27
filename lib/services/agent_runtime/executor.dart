import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'goal_tree.dart';
import 'json_utils.dart';
import 'prompt_constants.dart';
import 'prompt_templates.dart';
import 'runtime_logger.dart';
import 'runtime_models.dart';

/// Executes the tool selection and review loop.
class Executor {
  Executor({required this.client, required this.config});

  final OpenAiCompatibleClient client;
  final LlmProviderConfig config;

  /// Select the next tool or decide final response.
  Future<Map<String, dynamic>?> selectTool({
    required Map<String, dynamic> plan,
    required int currentStep,
    required List<Map<String, dynamic>> previousResults,
    required List<String> availableTools,
    required RuntimeLogger logger,
    String recentToolMemory = '',
    bool isWorkflowAutoExecute = false,
    GoalTree? goalTree,
  }) async {
    final prompt = PromptTemplates.selectToolPrompt(
      plan: plan,
      currentStep: currentStep,
      previousResults: previousResults,
      availableTools: availableTools,
      recentToolMemory: recentToolMemory,
      isWorkflowAutoExecute: isWorkflowAutoExecute,
      goalTree: goalTree,
    );

    return _callLlm(prompt, 'selectTool', logger);
  }

  /// Review a tool result and decide next action.
  Future<Map<String, dynamic>?> review({
    required ToolExecutionResult result,
    required Map<String, dynamic> plan,
    required int currentStep,
    required String userMessage,
    required RuntimeLogger logger,
    String language = 'Indonesian',
    GoalTree? goalTree,
  }) async {
    final prompt = PromptTemplates.reviewPrompt(
      result: result,
      plan: plan,
      currentStep: currentStep,
      userMessage: userMessage,
      language: language,
      goalTree: goalTree,
    );

    return _callLlm(prompt, 'review', logger);
  }

  /// Call LLM and parse JSON. Retries once with repair prompt.
  Future<Map<String, dynamic>?> _callLlm(
    String prompt,
    String phase,
    RuntimeLogger logger,
  ) async {
    final response = await client.chat(
      config: config,
      phase: phase,
      messages: [
        {'role': 'system', 'content': PromptConstants.jsonOnlySystem},
        {'role': 'user', 'content': prompt},
      ],
    );

    var parsed = JsonUtils.tryParseObject(response);
    if (parsed != null) {
      logger.logLlmDecision(phase, parsed);
      return parsed;
    }

    // Retry with repair.
    logger.logError('JSON parse failed in $phase, attempting repair');
    final repairPrompt = PromptTemplates.jsonRepairPrompt(response);
    final repaired = await client.chat(
      config: config,
      phase: '$phase.repair',
      messages: [
        {'role': 'user', 'content': repairPrompt},
      ],
    );

    parsed = JsonUtils.tryParseObject(repaired);
    if (parsed != null) {
      logger.logLlmDecision(phase, parsed);
      return parsed;
    }

    logger.logError('JSON repair also failed in $phase');
    return null;
  }
}
