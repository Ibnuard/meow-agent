import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'json_utils.dart';
import 'pending_action.dart';
import 'prompt_constants.dart';
import 'prompt_templates.dart';
import 'runtime_logger.dart';
import 'runtime_models.dart';

/// Analyzes user intent and creates an execution plan via LLM.
class Planner {
  Planner({
    required this.client,
    required this.config,
    required this.languageCode,
  });

  final OpenAiCompatibleClient client;
  final LlmProviderConfig config;
  final String languageCode;

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
    );

    final result = await _callLlm(prompt, 'analyze', logger);
    return result;
  }

  /// Create execution plan from analysis. Returns parsed JSON or null.
  Future<Map<String, dynamic>?> plan({
    required Map<String, dynamic> analysis,
    required List<String> availableTools,
    required RuntimeLogger logger,
  }) async {
    final prompt = PromptTemplates.planPrompt(
      analysis: analysis,
      availableTools: availableTools,
    );

    final result = await _callLlm(prompt, 'plan', logger);
    return result;
  }

  /// Call LLM and parse JSON response. Retries once with repair prompt.
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

    // Try parsing.
    var parsed = JsonUtils.tryParseObject(response);
    if (parsed != null) {
      logger.logLlmDecision(phase, parsed);
      return parsed;
    }

    // Retry with repair prompt.
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
