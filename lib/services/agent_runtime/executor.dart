import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'goal_tree.dart';
import 'llm_json_caller.dart';
import 'prompt_templates.dart';
import 'runtime_logger.dart';
import 'runtime_models.dart';

/// Executes the tool selection and review loop.
class Executor {
  Executor({required this.client, required this.config});

  final OpenAiCompatibleClient client;
  final LlmProviderConfig config;

  LlmJsonCaller get _caller => LlmJsonCaller(client: client, config: config);

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
    List<Map<String, String>> recentMessages = const [],
  }) async {
    final prompt = PromptTemplates.selectToolPrompt(
      plan: plan,
      currentStep: currentStep,
      previousResults: previousResults,
      availableTools: availableTools,
      recentToolMemory: recentToolMemory,
      isWorkflowAutoExecute: isWorkflowAutoExecute,
      goalTree: goalTree,
      recentMessages: recentMessages,
    );

    return _caller.call(prompt, 'selectTool', logger);
  }

  /// Review a tool result and decide next action.
  Future<Map<String, dynamic>?> review({
    required ToolExecutionResult result,
    required Map<String, dynamic> plan,
    required int currentStep,
    required String userMessage,
    required RuntimeLogger logger,
    String language = 'English',
    GoalTree? goalTree,
    List<Map<String, String>> recentMessages = const [],
  }) async {
    final prompt = PromptTemplates.reviewPrompt(
      result: result,
      plan: plan,
      currentStep: currentStep,
      userMessage: userMessage,
      language: language,
      goalTree: goalTree,
      recentMessages: recentMessages,
    );

    return _caller.call(prompt, 'review', logger);
  }
}
