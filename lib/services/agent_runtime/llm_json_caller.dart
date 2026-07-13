import 'package:dio/dio.dart';

import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'json_utils.dart';
import 'prompt_constants.dart';
import 'prompt_templates.dart';
import 'runtime_logger.dart';

/// Shared utility for Planner and Executor: calls the LLM for a structured
/// JSON response, retrying once with a repair prompt on parse failure.
class LlmJsonCaller {
  const LlmJsonCaller({
    required this.client,
    required this.config,
    this.cancelToken,
  });

  final OpenAiCompatibleClient client;
  final LlmProviderConfig config;

  /// Aborts the in-flight HTTP request when the user cancels the task.
  final CancelToken? cancelToken;

  /// Sends [prompt] to the LLM under [phase], expecting a JSON object back.
  /// Returns the parsed `Map<String, dynamic>` on success, or `null` if both
  /// the initial call and the repair retry fail to produce valid JSON.
  ///
  /// When [stableContext] is provided, it is sent as a separate user message
  /// BEFORE [prompt]. This enables provider-side prompt caching: the system
  /// message + stableContext form a byte-identical prefix across all phases
  /// in a turn, so the provider reuses the cached prefix instead of
  /// re-processing it. See REVIEWED.md Level 2: Stable Prompt Prefix.
  Future<Map<String, dynamic>?> call(
    String prompt,
    String phase,
    RuntimeLogger logger, {
    String? stableContext,
  }) async {
    final baseMessages = <Map<String, String>>[
      {'role': 'system', 'content': PromptConstants.jsonOnlySystem},
      if (stableContext != null && stableContext.isNotEmpty)
        {'role': 'user', 'content': stableContext},
      {'role': 'user', 'content': prompt},
    ];

    final response = await client.chat(
      config: config,
      phase: phase,
      cancelToken: cancelToken,
      messages: baseMessages,
    );

    var parsed = JsonUtils.tryParseObject(response);
    if (parsed != null) {
      logger.logLlmDecision(phase, parsed, version: PromptConstants.promptVersion);
      return parsed;
    }

    // Retry with repair prompt.
    logger.logError('JSON parse failed in $phase, attempting repair');
    final repairPrompt = PromptTemplates.jsonRepairPrompt(response);
    final repaired = await client.chat(
      config: config,
      phase: '$phase.repair',
      cancelToken: cancelToken,
      messages: [
        {'role': 'user', 'content': repairPrompt},
      ],
    );

    parsed = JsonUtils.tryParseObject(repaired);
    if (parsed != null) {
      logger.logLlmDecision(phase, parsed, version: PromptConstants.promptVersion);
      return parsed;
    }

    logger.logError('JSON repair also failed in $phase');
    return null;
  }
}