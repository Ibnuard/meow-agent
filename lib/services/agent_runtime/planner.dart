import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'llm_json_caller.dart';
import 'pending_action.dart';
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

  LlmJsonCaller get _caller => LlmJsonCaller(client: client, config: config);

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

    final result = await _caller.call(prompt, 'analyze', logger);
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

    final result = await _caller.call(prompt, 'plan', logger);
    return result;
  }
}
