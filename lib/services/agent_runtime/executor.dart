import 'package:dio/dio.dart';

import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'goal_tree.dart';
import 'llm_json_caller.dart';
import 'prompt_templates.dart';
import 'runtime_logger.dart';
import 'runtime_models.dart';
import 'tool_schema_converter.dart';

/// Executes the tool selection and review loop.
class Executor {
  Executor({required this.client, required this.config, this.cancelToken});

  final OpenAiCompatibleClient client;
  final LlmProviderConfig config;
  final CancelToken? cancelToken;

  LlmJsonCaller get _caller =>
      LlmJsonCaller(client: client, config: config, cancelToken: cancelToken);

  /// Select the next tool or decide final response.
  Future<Map<String, dynamic>?> selectTool({
    required Map<String, dynamic> plan,
    required int currentStep,
    required List<Map<String, dynamic>> previousResults,
    required List<String> availableTools,
    required RuntimeLogger logger,
    String userMessage = '',
    String recentToolMemory = '',
    bool isWorkflowAutoExecute = false,
    GoalTree? goalTree,
    List<Map<String, String>> recentMessages = const [],
    String agentName = '',
    String agentId = '',
    String? stableContext,
  }) async {
    // Sort tools for deterministic ordering across multiple selectTool
    // calls in the same loop — enables provider prefix cache hits.
    final sortedTools = List<String>.from(availableTools)..sort();
    final prompt = PromptTemplates.selectToolPrompt(
      plan: plan,
      currentStep: currentStep,
      previousResults: previousResults,
      availableTools: sortedTools,
      userMessage: userMessage,
      recentToolMemory: recentToolMemory,
      isWorkflowAutoExecute: isWorkflowAutoExecute,
      goalTree: goalTree,
      recentMessages: recentMessages,
      agentName: agentName,
      agentId: agentId,
    );

    return _caller.call(
      prompt,
      'selectTool',
      logger,
      stableContext: stableContext,
    );
  }

  /// Review a tool result and decide next action.
  Future<Map<String, dynamic>?> review({
    required ToolExecutionResult result,
    required Map<String, dynamic> plan,
    required int currentStep,
    required String userMessage,
    required RuntimeLogger logger,
    List<Map<String, dynamic>> previousResults = const [],
    String language = 'English',
    GoalTree? goalTree,
    List<Map<String, String>> recentMessages = const [],
    String agentName = '',
    String agentId = '',
    String? stableContext,
  }) async {
    final prompt = PromptTemplates.reviewPrompt(
      result: result,
      plan: plan,
      currentStep: currentStep,
      userMessage: userMessage,
      previousResults: previousResults,
      language: language,
      goalTree: goalTree,
      recentMessages: recentMessages,
      agentName: agentName,
      agentId: agentId,
    );

    return _caller.call(
      prompt,
      'review',
      logger,
      stableContext: stableContext,
    );
  }

  /// Fast-path tool selection via native function calling.
  ///
  /// Sends the tool definitions as an OpenAI `tools` API parameter and reads
  /// the model's `tool_calls` response directly — no JSON-in-content parsing.
  /// Returns a [ToolCallRequest] on success, or null if the model returned no
  /// tool call (caller should fall back to [selectTool]).
  ///
  /// The risk/confirmation values come from the [ToolDefinition] (authoritative
  /// runtime metadata), NOT from the model — the model only picks the tool and
  /// its args.
  Future<ToolCallRequest?> selectToolViaFunctionCalling({
    required List<ToolDefinition> tools,
    required String userGoal,
    required List<Map<String, String>> recentMessages,
    required RuntimeLogger logger,
  }) async {
    if (!config.supportsFunctionCalling || tools.isEmpty) return null;

    final openAiTools = ToolSchemaConverter.toOpenAiTools(tools);
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content':
            'You are a tool selector. Pick the single most appropriate tool '
            'for the user\'s request and fill its arguments. Respond with a '
            'tool call only.',
      },
      for (final m in recentMessages) {'role': m['role'], 'content': m['content']},
      {'role': 'user', 'content': userGoal},
    ];

    try {
      final result = await client.chatWithTools(
        config: config,
        messages: messages,
        tools: openAiTools,
        toolChoice: 'required',
        phase: 'fc_select',
        cancelToken: cancelToken,
      );
      if (result == null) {
        logger.logStateChange(
          AgentRuntimeState.selectingTool,
          'Function calling returned no tool_call; falling back to JSON selector',
        );
        return null;
      }

      // Match the selected tool name against the authoritative definition to
      // pull risk + confirmation metadata (never trust the model for these).
      final def = tools.where((t) => t.name == result.toolName).firstOrNull;
      if (def == null) {
        logger.logStateChange(
          AgentRuntimeState.selectingTool,
          'Function calling picked unknown tool "${result.toolName}"; falling back',
        );
        return null;
      }

      logger.logStateChange(
        AgentRuntimeState.selectingTool,
        'Function calling selected ${def.name}',
      );
      return ToolCallRequest(
        name: def.name,
        args: result.args,
        risk: def.risk,
        requiresConfirmation: def.requiresConfirmation,
      );
    } catch (e) {
      logger.logError('Function calling selection failed', e);
      return null;
    }
  }
}
