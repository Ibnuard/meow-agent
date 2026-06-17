import '../../core/storage/agent_memory_repository.dart';
import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'json_utils.dart';
import 'prompt_constants.dart';
import 'runtime_logger.dart';
import 'runtime_models.dart';

/// Post-task memory extractor.
///
/// After a successful tool-assisted task, this class sends a lightweight LLM
/// call to identify implicit user preferences, facts, or patterns worth
/// remembering — things the user didn't explicitly say "remember this" for.
///
/// Design constraints:
/// - Fire-and-forget: extraction failures never break the turn.
/// - Deduplication: skip if content already exists in recent memory.
/// - Token-light: uses a short prompt with only the current turn's context.
/// - Conservative: better to miss a fact than pollute memory with noise.
class MemoryExtractor {
  MemoryExtractor({
    required this.client,
    required this.config,
    required this.memoryRepo,
  });

  final OpenAiCompatibleClient client;
  final LlmProviderConfig config;
  final AgentMemoryRepository memoryRepo;

  /// Minimum user message length to consider extraction worthwhile.
  /// Very short messages ("ok", "yes") rarely carry implicit facts.
  static const int _minMessageLength = 15;

  /// Max entries to check for deduplication.
  static const int _dedupePoolSize = 30;

  /// Analyze the completed turn and extract any implicit facts/preferences.
  ///
  /// Returns the number of entries appended (0 if nothing extracted).
  /// Never throws — all errors are swallowed.
  Future<int> extractAfterTask({
    required String agentId,
    required String userMessage,
    required List<Map<String, dynamic>> toolResults,
    required RuntimeLogger logger,
  }) async {
    try {
      if (userMessage.trim().length < _minMessageLength) return 0;
      if (toolResults.isEmpty) return 0;

      final prompt = _buildPrompt(
        userMessage: userMessage,
        toolResults: toolResults,
      );

      final response = await client.chat(
        config: config,
        phase: 'memory_extract',
        messages: [
          {'role': 'system', 'content': PromptConstants.memoryExtractionSystem},
          {'role': 'user', 'content': prompt},
        ],
      );

      final parsed = JsonUtils.tryParseObject(response);
      if (parsed == null) return 0;

      final entries = parsed['entries'] as List?;
      if (entries == null || entries.isEmpty) return 0;

      // Fetch recent memory for deduplication.
      final existing = await memoryRepo.recent(agentId, limit: _dedupePoolSize);
      final existingContents = existing
          .map((e) => e.content.toLowerCase().trim())
          .toSet();

      var count = 0;
      for (final raw in entries) {
        if (raw is! Map) continue;
        final content = (raw['content'] ?? '').toString().trim();
        final category = (raw['category'] ?? 'fact').toString().trim();
        if (content.isEmpty || content.length < 5) continue;

        // Skip duplicates.
        if (_isDuplicate(content, existingContents)) continue;

        await memoryRepo.append(
          agentId: agentId,
          content: content,
          category: category,
        );
        existingContents.add(content.toLowerCase().trim());
        count++;
      }

      if (count > 0) {
        logger.logStateChange(
          AgentRuntimeState.done,
          'Memory extractor: auto-saved $count entr${count == 1 ? 'y' : 'ies'}',
        );
      }
      return count;
    } catch (_) {
      // Fire-and-forget — never break the turn.
      return 0;
    }
  }

  /// Check if a new entry is semantically a duplicate of existing ones.
  static bool _isDuplicate(String content, Set<String> existing) {
    final normalized = content.toLowerCase().trim();
    if (existing.contains(normalized)) return true;

    // Fuzzy match: if 80%+ of words overlap with an existing entry, skip.
    final newWords = normalized.split(RegExp(r'\s+')).toSet();
    if (newWords.length < 3) {
      return existing.contains(normalized);
    }
    for (final ex in existing) {
      final exWords = ex.split(RegExp(r'\s+')).toSet();
      final overlap = newWords.intersection(exWords).length;
      if (overlap / newWords.length >= 0.8) return true;
    }
    return false;
  }

  String _buildPrompt({
    required String userMessage,
    required List<Map<String, dynamic>> toolResults,
  }) {
    final toolBlock = toolResults
        .take(5)
        .map((r) {
          final tool = r['tool'] ?? '';
          final success = r['result'] != null;
          final args = r['args'] ?? r['result'] ?? {};
          return '- $tool (${success ? 'ok' : 'fail'}): $args';
        })
        .join('\n');

    return PromptConstants.memoryExtractionUser(
      userMessage: userMessage,
      toolBlock: toolBlock,
    );
  }
}
