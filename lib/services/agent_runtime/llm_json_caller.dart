import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'json_utils.dart';
import 'prompt_constants.dart';
import 'prompt_templates.dart';
import 'runtime_logger.dart';

/// Shared utility for Planner and Executor: calls the LLM for a structured
/// JSON response, retrying once with a repair prompt on parse failure.
class LlmJsonCaller {
  const LlmJsonCaller({required this.client, required this.config});

  final OpenAiCompatibleClient client;
  final LlmProviderConfig config;

  /// Sends [prompt] to the LLM under [phase], expecting a JSON object back.
  /// Returns the parsed `Map<String, dynamic>` on success, or `null` if both
  /// the initial call and the repair retry fail to produce valid JSON.
  Future<Map<String, dynamic>?> call(
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