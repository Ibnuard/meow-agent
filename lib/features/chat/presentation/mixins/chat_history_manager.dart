import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/chat_history_service.dart';
import '../../data/chat_messages_notifier.dart';
import '../../data/chat_runtime_manager.dart';
import '../../../../services/agent_runtime/context_compactor.dart';
import '../../../../services/agent_runtime/runtime_models.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../../modules/calendar/calendar_screen.dart';
import '../../../modules/workflows/workflow_list_screen.dart';
import '../../../agents/data/workspace_service.dart';
import '../../../agents/data/agent_repository.dart';
import '../../../providers/data/provider_repository.dart';
import '../../data/token_usage_service.dart';

/// History loading, persistence, and message action handling.
mixin ChatHistoryManagerMixin<T extends StatefulWidget> on State<T> {
  AppStrings get s;
  String get activeAgentId;
  ChatRuntimeManager? get manager;
  ChatRuntimeManager ensureManager();
  void scrollToEnd();
  Future<ChatMessage> persistMessage(ChatMessage message);
  WidgetRef get ref;
  ScrollController get chatScroll;
  void Function() get rebuildDateBoundaries;

  /// Convenience accessor for the active agent's message notifier.
  ChatMessagesNotifier get _notifier =>
      ref.read(chatMessagesProvider(activeAgentId).notifier);

  /// Current messages from the notifier (read-only snapshot).
  List<ChatMessage> get messagesList =>
      ref.read(chatMessagesProvider(activeAgentId)).messages;

  /// Whether more older messages might exist.
  bool get hasMore => ref.read(chatMessagesProvider(activeAgentId)).hasMore;

  /// Whether older messages are currently being fetched.
  bool get loadingOlder =>
      ref.read(chatMessagesProvider(activeAgentId)).loadingOlder;

  /// Whether initial history is still loading.
  bool get initialLoading =>
      ref.read(chatMessagesProvider(activeAgentId)).initialLoading;

  /// Reload history from disk after manager persists a reply.
  Future<void> reloadHistory(
    String agentId, {
    bool scrollToBottom = true,
  }) async {
    final notifier = ref.read(chatMessagesProvider(agentId).notifier);
    await notifier.reload(manager: manager);
    rebuildDateBoundaries();
    if (scrollToBottom) scrollToEnd();
  }

  void handleConfirmation(String action, int msgIndex) {
    final messages = messagesList;
    if (msgIndex < 0 || msgIndex >= messages.length) return;

    final msg = messages[msgIndex];
    _notifier.removeAt(msgIndex);
    if (msg.id != null) {
      deletePersistedMessage(msg.id!);
    }

    final mgr = ensureManager();

    switch (action) {
      case 'accept':
      case 'always_accept':
        mgr.confirm(activeAgentId);
        break;
      case 'reject':
        mgr.reject(activeAgentId);
        break;
    }
  }

  Future<void> handleResultAction(
    ResultAction action, [
    ChatMessage? sourceMessage,
  ]) async {
    switch (action.type) {
      case 'select_model':
        await handleSelectModelAction(action, sourceMessage);
        break;
      case 'navigate':
        if (action.target == '/modules/calendar') {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CalendarScreen()),
          );
        } else if (action.target == '/modules/workflows') {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const WorkflowListScreen()),
          );
        } else {
          if (!mounted) return;
          context.push(action.target);
        }
        break;
      case 'open_folder':
        final ws = ref.read(workspaceServiceProvider);
        await ws.openInFileManager(action.target);
        break;
      case 'open_url':
        break;
    }
  }

  Future<void> handleSelectModelAction(
    ResultAction action,
    ChatMessage? sourceMessage,
  ) async {
    final model = action.target.trim();
    if (model.isEmpty) return;
    final agents = ref.read(agentListProvider);
    final providers = ref.read(providerListProvider).value ?? [];
    final agent = activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == activeAgentId).firstOrNull;
    if (agent == null) return;
    final provider = providers
        .where((p) => p.id == agent.providerId)
        .firstOrNull;
    if (provider == null || !provider.models.contains(model)) return;

    await ref
        .read(agentListProvider.notifier)
        .save(agent.copyWith(model: model));
    final fixed = ChatMessage(
      id: sourceMessage?.id,
      role: 'assistant',
      timestamp: sourceMessage?.timestamp,
      content: s.modelUpdated(provider.nickname, model),
    );
    if (!mounted) return;

    final messages = messagesList;
    final idx = sourceMessage == null
        ? -1
        : messages.indexWhere(
            (m) => identical(m, sourceMessage) || m.id == sourceMessage.id,
          );
    if (idx >= 0) {
      _notifier.replaceAt(idx, fixed);
    }

    if (fixed.id != null) {
      await ref.read(chatHistoryServiceProvider).updateMessage(fixed);
    }
  }

  Future<void> deletePersistedMessage(int id) async {
    final service = ref.read(chatHistoryServiceProvider);
    await service.deleteMessage(id);
  }

  /// Load the latest page of messages for an agent.
  Future<void> loadHistory(String agentId) async {
    final notifier = ref.read(chatMessagesProvider(agentId).notifier);
    await notifier.loadInitial(manager: manager);
    rebuildDateBoundaries();

    final tokenService = ref.read(tokenUsageServiceProvider);
    final peak = await tokenService.getPersistedPeak(agentId);
    if (peak > 0) ContextCompactor.setPersistedPeak(peak);
  }

  /// Load older messages when scrolling to the top.
  ///
  /// With a reversed ListView, prepended items (at array index 0) map to the
  /// highest builder indices — i.e. they extend beyond maxScrollExtent
  /// (visually at the top). The viewport never shifts, so zero scroll
  /// correction is needed. This is the standard Flutter chat pattern.
  Future<void> loadOlderMessages() async {
    final count = await _notifier.loadOlder();
    if (count > 0) {
      rebuildDateBoundaries();
    }
  }
}
