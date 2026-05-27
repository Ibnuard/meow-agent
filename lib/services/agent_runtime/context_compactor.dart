import '../../features/chat/data/chat_history_service.dart';
import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'prompt_constants.dart';

/// Estimates token count and compacts conversation context when threshold is reached.
class ContextCompactor {
  ContextCompactor();

  /// How many recent LLM calls to inspect when computing peak input usage.
  /// 8 covers ~2 full agentic turns (analyze → plan → selectTool → review).
  static const int _peakLookbackWindow = 8;

  /// Compaction trigger threshold (fraction of max context length).
  static const double _compactionThreshold = 0.80;

  /// Rough token estimation: ~3.2 chars per token for mixed EN/ID content.
  /// This is a conservative estimate to avoid exceeding limits.
  static int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    return (text.length / 3.2).ceil();
  }

  /// Estimate total tokens for a list of messages.
  static int estimateMessagesTokens(List<Map<String, String>> messages) {
    var total = 0;
    for (final msg in messages) {
      // Each message has ~4 tokens overhead (role, formatting).
      total += 4;
      total += estimateTokens(msg['content'] ?? '');
    }
    return total;
  }

  /// Estimate tokens from ChatMessage list.
  static int estimateChatTokens(List<ChatMessage> messages) {
    var total = 0;
    for (final msg in messages) {
      total += 4;
      total += estimateTokens(msg.content);
    }
    return total;
  }

  /// Peak inputTokens across the last [_peakLookbackWindow] LLM calls.
  ///
  /// This is the source of truth for context pressure. The chat history
  /// estimate vastly under-counts what actually goes to the LLM (system
  /// rules + workspace files + tool catalog + recent messages all add up
  /// per call). Returns 0 if no LLM call has been recorded yet.
  static int peakRecentInputTokens() {
    final records = OpenAiCompatibleClient.usageRecords;
    if (records.isEmpty) return 0;
    final start = records.length > _peakLookbackWindow
        ? records.length - _peakLookbackWindow
        : 0;
    var peak = 0;
    for (var i = start; i < records.length; i++) {
      final v = records[i].inputTokens;
      if (v > peak) peak = v;
    }
    return peak;
  }

  /// Check if context needs compaction.
  ///
  /// Prefers the measured peak from recent LLM calls (real payload size).
  /// Falls back to chat history estimation for cold start (no calls yet).
  static bool needsCompaction({
    required List<ChatMessage> messages,
    required int maxContextLength,
    double threshold = _compactionThreshold,
  }) {
    final peak = peakRecentInputTokens();
    final estimated = peak > 0 ? peak : estimateChatTokens(messages);
    return estimated >= (maxContextLength * threshold).toInt();
  }

  /// Compact messages by summarizing older messages into a single summary.
  /// Keeps the most recent [keepRecent] messages intact.
  /// Returns the compacted message list.
  Future<List<ChatMessage>> compact({
    required List<ChatMessage> messages,
    required LlmProviderConfig config,
    int keepRecent = 6,
  }) async {
    if (messages.length <= keepRecent + 2) return messages;

    // Split: older messages to summarize, recent to keep.
    final olderMessages = messages.sublist(0, messages.length - keepRecent);
    final recentMessages = messages.sublist(messages.length - keepRecent);

    // Build summary prompt.
    final historyText = olderMessages
        .map((m) => '${m.role}: ${m.content}')
        .join('\n');

    final client = OpenAiCompatibleClient();
    final summary = await client.chat(
      config: config,
      phase: 'compact',
      messages: [
        {'role': 'system', 'content': PromptConstants.compactorSystemPrompt},
        {'role': 'user', 'content': historyText},
      ],
    );

    // Create compacted list: summary + recent messages.
    final summaryMessage = ChatMessage(
      role: 'assistant',
      content: '📋 *Ringkasan percakapan sebelumnya:*\n$summary',
    );

    return [summaryMessage, ...recentMessages];
  }

  /// Get context usage info.
  ///
  /// Returns:
  /// - `estimated`: best available estimate (measured peak or chat fallback)
  /// - `chatTokens`: chat-history-only estimate (for reference)
  /// - `peakMeasured`: peak inputTokens from recent LLM calls (0 if none yet)
  /// - `source`: 'measured' if a real LLM call drives the number, else 'estimated'
  /// - `max`, `percentage`, `needsCompact`: derived from `estimated`.
  static ({
    int estimated,
    int chatTokens,
    int peakMeasured,
    String source,
    int max,
    double percentage,
    bool needsCompact,
  })
  getUsageInfo({
    required List<ChatMessage> messages,
    required int maxContextLength,
  }) {
    final chatTokens = estimateChatTokens(messages);
    final peakMeasured = peakRecentInputTokens();
    final estimated = peakMeasured > 0 ? peakMeasured : chatTokens;
    final percentage = maxContextLength > 0
        ? (estimated / maxContextLength * 100)
        : 0.0;
    return (
      estimated: estimated,
      chatTokens: chatTokens,
      peakMeasured: peakMeasured,
      source: peakMeasured > 0 ? 'measured' : 'estimated',
      max: maxContextLength,
      percentage: percentage,
      needsCompact:
          estimated >= (maxContextLength * _compactionThreshold).toInt(),
    );
  }
}
