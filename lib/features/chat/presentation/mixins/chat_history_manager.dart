import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/chat_history_service.dart';
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
  List<ChatMessage> get messagesList;
  Map<String, List<ChatMessage>> get messagesByAgent;
  Set<String> get fullyLoaded;
  ChatRuntimeManager? get manager;
  ChatRuntimeManager ensureManager();
  void scrollToEnd();
  Future<ChatMessage> persistMessage(ChatMessage message);
  WidgetRef get ref;

  /// Reload history from disk after manager persists a reply.
  Future<void> reloadHistory(String agentId) async {
    final service = ref.read(chatHistoryServiceProvider);
    final history = await service.loadLatest(agentId);

    final hasPending = manager?.sessionFor(agentId).pendingTool != null;
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
          ChatMessage(
            id: m.id,
            role: m.role,
            content: m.content
                .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
                .trim(),
            actions: m.actions,
          ),
        );
      } else {
        cleaned.add(m);
      }
    }

    if (!mounted) return;
    setState(() {
      messagesByAgent[agentId] = cleaned;
    });
    scrollToEnd();
  }

  void handleConfirmation(String action, int msgIndex) {
    if (msgIndex < 0 || msgIndex >= messagesList.length) return;

    final msg = messagesList[msgIndex];
    setState(() => messagesList.removeAt(msgIndex));
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
    setState(() {
      final idx = sourceMessage == null
          ? -1
          : messagesList.indexWhere(
              (m) => identical(m, sourceMessage) || m.id == sourceMessage.id,
            );
      if (idx >= 0) {
        messagesList[idx] = fixed;
      }
    });
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
    if (messagesByAgent.containsKey(agentId)) {
      if (initialLoading) setState(() => initialLoading = false);
      return;
    }
    messagesByAgent[agentId] = [];

    final service = ref.read(chatHistoryServiceProvider);
    final history = await service.loadLatest(agentId);

    final ChatRuntimeManager mgr =
        manager ?? ref.read(chatRuntimeManagerProvider);
    final hasPending = mgr.sessionFor(agentId).pendingTool != null;
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
          ChatMessage(
            id: m.id,
            role: m.role,
            content: m.content
                .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
                .trim(),
            actions: m.actions,
          ),
        );
      } else {
        cleaned.add(m);
      }
    }

    if (mounted) {
      setState(() {
        final live = messagesByAgent[agentId] ?? [];
        messagesByAgent[agentId] = [...cleaned, ...live];
        initialLoading = false;
      });
      rebuildDateBoundaries();
      if (cleaned.length < kMessagePageSize) {
        fullyLoaded.add(agentId);
      }
      // Reversed list starts at position 0 = bottom (newest). No jump needed.
    }

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
    if (loadingOlder || !hasMore) return;
    final messages = messagesList;
    if (messages.isEmpty) return;

    final oldestId = messages.first.id;
    if (oldestId == null) {
      fullyLoaded.add(activeAgentId);
      return;
    }

    loadingOlder = true;
    setState(() {});

    final service = ref.read(chatHistoryServiceProvider);
    final older = await service.loadOlder(
      activeAgentId,
      beforeId: oldestId,
      limit: kMessagePageSize,
    );

    if (!mounted || older.isEmpty) {
      if (mounted) {
        setState(() {
          loadingOlder = false;
          if (older.isEmpty) fullyLoaded.add(activeAgentId);
        });
      }
      return;
    }

    setState(() {
      messages.insertAll(0, older);
      loadingOlder = false;
      if (older.length < kMessagePageSize) {
        fullyLoaded.add(activeAgentId);
      }
    });

    rebuildDateBoundaries();
  }

  // State accessors needed by this mixin.
  bool get initialLoading;
  set initialLoading(bool value);
  bool get loadingOlder;
  set loadingOlder(bool value);
  bool get hasMore;
  ScrollController get chatScroll;
  void Function() get rebuildDateBoundaries;
}
