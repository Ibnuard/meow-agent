import '../llm/llm_error_mapper.dart';
import '../../features/chat/data/chat_history_service.dart';

/// Slices conversation history for LLM prompts without losing the original
/// user goal.
///
/// The runtime previously hard-capped history to the latest 20 messages and
/// silently dropped everything older. On a complex multi-step task (many tool
/// results + narratives across turns) the original user request — the goal
/// the selector and reviewer must stay anchored to — got pushed out of the
/// window, causing goal drift: the agent lost sight of what it was trying to
/// accomplish and started acting on recent chatter alone.
///
/// [sliceHistory] keeps the earliest user message (the session's original goal)
/// pinned at the front, then appends the most recent messages up to [window].
/// This guarantees the goal is visible to every selector/reviewer prompt while
/// still bounding context growth. Provider-error sentinel messages are
/// stripped first — they describe a past connection failure, not real context.
class HistorySlicer {
  HistorySlicer._();

  /// Number of recent messages kept after the pinned original goal.
  ///
  /// Raised from the previous hard cap of 20 to give complex multi-step tasks
  /// more working context before the compactor's token-based pruning takes
  /// over. The compactor remains the authority on absolute token pressure;
  /// this window only governs the message-count slice.
  static const int defaultWindow = 30;

  /// Slice [messages] into a prompt-ready role/content list.
  ///
  /// Returns messages in chronological order with the original user goal
  /// (the first user message in the filtered source) pinned at index 0 when
  /// the window would otherwise have dropped it.
  static List<Map<String, String>> slice({
    required List<ChatMessage> messages,
    int window = defaultWindow,
  }) {
    final usable = messages
        .where(
          (m) =>
              m.includeInRuntimeContext &&
              !LlmErrorMapper.isProviderErrorMessage(m.content),
        )
        .toList();
    if (usable.length <= window) {
      return usable.map((m) => {'role': m.role, 'content': m.content}).toList();
    }

    // Pin the original user goal so it is never lost behind the recent window.
    final originalGoal = _firstUser(usable);
    final recent = usable.sublist(usable.length - window);
    if (originalGoal != null && !recent.contains(originalGoal)) {
      return [
        {'role': originalGoal.role, 'content': originalGoal.content},
        ...recent.map((m) => {'role': m.role, 'content': m.content}),
      ];
    }
    return recent.map((m) => {'role': m.role, 'content': m.content}).toList();
  }

  static ChatMessage? _firstUser(List<ChatMessage> messages) {
    for (final m in messages) {
      if (m.role == 'user') return m;
    }
    return null;
  }
}
