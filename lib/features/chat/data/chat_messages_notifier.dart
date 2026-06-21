import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_history_service.dart';
import 'chat_runtime_manager.dart';

/// Immutable state for a single agent's chat messages.
class ChatState {
  const ChatState({
    this.messages = const [],
    this.initialLoading = true,
    this.loadingOlder = false,
    this.hasMore = true,
  });

  final List<ChatMessage> messages;
  final bool initialLoading;
  final bool loadingOlder;
  final bool hasMore;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? initialLoading,
    bool? loadingOlder,
    bool? hasMore,
  }) => ChatState(
    messages: messages ?? this.messages,
    initialLoading: initialLoading ?? this.initialLoading,
    loadingOlder: loadingOlder ?? this.loadingOlder,
    hasMore: hasMore ?? this.hasMore,
  );
}

/// Riverpod Family Notifier for managing chat messages per agent.
///
/// This isolates message-list mutations from the parent widget tree,
/// ensuring only the Consumer watching this provider rebuilds when
/// messages change — NOT the AppBar, Input, FAB, etc.
class ChatMessagesNotifier extends FamilyNotifier<ChatState, String> {
  @override
  ChatState build(String arg) => const ChatState();

  String get _agentId => arg;

  ChatHistoryService get _historyService =>
      ref.read(chatHistoryServiceProvider);

  /// Load the initial page of messages from local storage.
  /// Called once when the chat screen opens for an agent.
  Future<void> loadInitial({ChatRuntimeManager? manager}) async {
    // Already loaded — skip.
    if (state.messages.isNotEmpty || !state.initialLoading) return;

    final history = await _historyService.loadLatest(_agentId);
    final cleaned = _cleanConfirmations(history, manager);

    state = state.copyWith(
      messages: cleaned,
      initialLoading: false,
      hasMore: cleaned.length >= kMessagePageSize,
    );
  }

  /// Load older messages (pagination). Returns the count loaded.
  Future<int> loadOlder() async {
    if (state.loadingOlder || !state.hasMore) return 0;
    if (state.messages.isEmpty) return 0;

    final oldestId = state.messages.first.id;
    if (oldestId == null) {
      state = state.copyWith(hasMore: false);
      return 0;
    }

    state = state.copyWith(loadingOlder: true);

    final older = await _historyService.loadOlder(
      _agentId,
      beforeId: oldestId,
      limit: kMessagePageSize,
    );

    if (older.isEmpty) {
      state = state.copyWith(loadingOlder: false, hasMore: false);
      return 0;
    }

    state = state.copyWith(
      messages: [...older, ...state.messages],
      loadingOlder: false,
      hasMore: older.length >= kMessagePageSize,
    );
    return older.length;
  }

  /// Add a single message to the end (newest). Used for send + bot replies.
  void addMessage(ChatMessage msg) {
    state = state.copyWith(messages: [...state.messages, msg]);
  }

  /// Insert a message or update its existing optimistic/persisted instance.
  void upsertMessage(ChatMessage msg) {
    final idx = state.messages.indexWhere((m) => _sameMessage(m, msg));
    if (idx < 0) {
      addMessage(msg);
      return;
    }
    replaceAt(idx, msg);
  }

  void upsertMessages(List<ChatMessage> messages) {
    if (messages.isEmpty) return;
    final updated = [...state.messages];
    var changed = false;
    for (final msg in messages) {
      final idx = updated.indexWhere((m) => _sameMessage(m, msg));
      if (idx < 0) {
        updated.add(msg);
      } else {
        updated[idx] = msg;
      }
      changed = true;
    }
    if (changed) state = state.copyWith(messages: updated);
  }

  void replaceByClientId(String clientId, ChatMessage msg) {
    final idx = state.messages.indexWhere((m) => m.clientId == clientId);
    if (idx >= 0) replaceAt(idx, msg);
  }

  void updateDeliveryStatus(
    String clientId,
    ChatMessageDeliveryStatus status, {
    String? errorMessage,
  }) {
    final idx = state.messages.indexWhere((m) => m.clientId == clientId);
    if (idx < 0) return;
    replaceAt(
      idx,
      state.messages[idx].copyWith(
        deliveryStatus: status,
        errorMessage: errorMessage,
        clearErrorMessage:
            errorMessage == null && status != ChatMessageDeliveryStatus.failed,
      ),
    );
  }

  /// Replace a message at a given index (e.g. after model selection action).
  void replaceAt(int index, ChatMessage msg) {
    if (index < 0 || index >= state.messages.length) return;
    final updated = [...state.messages];
    updated[index] = msg;
    state = state.copyWith(messages: updated);
  }

  /// Remove a message at a given index (e.g. confirmation bubble dismissed).
  void removeAt(int index) {
    if (index < 0 || index >= state.messages.length) return;
    final updated = [...state.messages];
    updated.removeAt(index);
    state = state.copyWith(messages: updated);
  }

  /// Replace all messages (used after reload from disk or compaction).
  void replaceAll(List<ChatMessage> messages, {bool? hasMore}) {
    state = state.copyWith(
      messages: messages,
      hasMore: hasMore ?? state.hasMore,
    );
  }

  /// Reload history from disk (after manager persists a new reply).
  Future<void> reload({ChatRuntimeManager? manager}) async {
    final history = await _historyService.loadLatest(_agentId);
    final cleaned = _cleanConfirmations(history, manager);

    state = state.copyWith(messages: cleaned, initialLoading: false);
  }

  /// Clear all messages for this agent.
  void clear() {
    state = const ChatState(initialLoading: false, hasMore: false);
  }

  /// Mark as fully loaded (no more older messages).
  void markFullyLoaded() {
    state = state.copyWith(hasMore: false);
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  /// Strip [[CONFIRMATION_REQUIRED]] from messages that are no longer live.
  List<ChatMessage> _cleanConfirmations(
    List<ChatMessage> history,
    ChatRuntimeManager? manager,
  ) {
    final hasPending = manager?.sessionFor(_agentId).pendingTool != null;
    int lastAssistantIdx = -1;
    for (var i = history.length - 1; i >= 0; i--) {
      if (history[i].role == 'assistant') {
        lastAssistantIdx = i;
        break;
      }
    }

    final cleaned = <ChatMessage>[];
    for (var i = 0; i < history.length; i++) {
      final m = history[i];
      final isLiveConfirmation = hasPending && i == lastAssistantIdx;
      if (!isLiveConfirmation &&
          m.content.contains('[[CONFIRMATION_REQUIRED]]')) {
        cleaned.add(
          m.copyWith(
            content: m.content
                .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
                .trim(),
          ),
        );
      } else {
        cleaned.add(m);
      }
    }
    return cleaned;
  }

  bool _sameMessage(ChatMessage a, ChatMessage b) {
    final aClientId = a.clientId;
    final bClientId = b.clientId;
    if (aClientId != null && bClientId != null && aClientId == bClientId) {
      return true;
    }
    final aId = a.id;
    final bId = b.id;
    return aId != null && bId != null && aId == bId;
  }
}

/// Family provider for chat messages, keyed by agent ID.
final chatMessagesProvider =
    NotifierProvider.family<ChatMessagesNotifier, ChatState, String>(
      ChatMessagesNotifier.new,
    );
