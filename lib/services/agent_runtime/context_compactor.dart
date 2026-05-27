import '../../features/chat/data/chat_history_service.dart';
import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'prompt_constants.dart';

/// Estimates token count and compacts conversation context when threshold is reached.
class ContextCompactor {
  ContextCompactor();

  /// Rough token estimation: ~4 chars per token for English, ~2.5 for mixed.
  /// This is a conservative estimate to avoid exceeding limits.
  static int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    // Use ~3.2 chars per token as a middle ground for mixed EN/ID content.
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

  /// Check if context needs compaction.
  /// Returns true if estimated tokens exceed threshold percentage of max.
  static bool needsCompaction({
    required List<ChatMessage> messages,
    required int maxContextLength,
    double threshold = 0.80,
  }) {
    final estimated = estimateChatTokens(messages);
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
  static ({int estimated, int max, double percentage, bool needsCompact})
  getUsageInfo({
    required List<ChatMessage> messages,
    required int maxContextLength,
  }) {
    final estimated = estimateChatTokens(messages);
    final percentage = maxContextLength > 0
        ? (estimated / maxContextLength * 100)
        : 0.0;
    return (
      estimated: estimated,
      max: maxContextLength,
      percentage: percentage,
      needsCompact: estimated >= (maxContextLength * 0.80).toInt(),
    );
  }
}
