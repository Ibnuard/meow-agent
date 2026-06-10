import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router.dart';
import '../../data/chat_history_service.dart';
import '../../data/chat_messages_notifier.dart';
import '../../data/chat_runtime_manager.dart';
import '../../../../services/agent_runtime/context_compactor.dart';
import '../../../../services/agent_runtime/runtime_models.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../../modules/calendar/calendar_screen.dart';
import '../../../modules/data/module_model.dart';
import '../../../modules/data/module_repository.dart';
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
        mgr.confirm(activeAgentId);
        break;
      case 'always_accept':
        mgr.confirm(activeAgentId, alwaysApprove: true);
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
      case 'install_module':
        await handleInstallModuleAction(action, sourceMessage);
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

  Future<void> handleInstallModuleAction(
    ResultAction action,
    ChatMessage? sourceMessage,
  ) async {
    final moduleId = (action.params['moduleId'] ?? action.target)
        .toString()
        .trim();
    if (moduleId.isEmpty) return;

    if (sourceMessage != null) {
      await _replaceActionSource(
        sourceMessage,
        sourceMessage.copyWith(actions: const []),
      );
    }

    final spec = ModuleRegistry.available
        .where((module) => module.id == moduleId)
        .firstOrNull;
    if (spec == null) {
      final message =
          (sourceMessage ?? ChatMessage(role: 'assistant', content: ''))
              .copyWith(
                content: s.moduleInstallUnavailable(moduleId),
                actions: [
                  ResultAction(
                    label: s.moduleStore,
                    icon: 'extension_rounded',
                    type: 'navigate',
                    target: AppRoutes.moduleStore,
                  ),
                ],
              );
      await _replaceActionSource(sourceMessage, message);
      return;
    }

    final repo = ref.read(moduleRepositoryProvider);
    final installed = await repo.getInstalled();
    final alreadyInstalled = installed.any((module) => module.id == moduleId);
    if (!alreadyInstalled) {
      await repo.install(spec);
      ref.invalidate(installedModulesProvider);
    }
    if (!mounted) return;

    final content = s.moduleInstalledForPreviousRequest(spec.name);
    final message =
        (sourceMessage ?? ChatMessage(role: 'assistant', content: '')).copyWith(
          content: content,
          actions: [
            ResultAction(
              label: s.openModuleAction(spec.name),
              icon: 'extension_rounded',
              type: 'navigate',
              target: '/modules/$moduleId',
              params: {'moduleId': moduleId},
            ),
          ],
        );
    await _replaceActionSource(sourceMessage, message);
  }

  Future<void> _replaceActionSource(
    ChatMessage? sourceMessage,
    ChatMessage replacement,
  ) async {
    if (sourceMessage == null) {
      _notifier.addMessage(replacement);
      await persistMessage(replacement);
      scrollToEnd();
      return;
    }

    final messages = messagesList;
    final idx = messages.indexWhere((m) {
      if (identical(m, sourceMessage)) return true;
      final sourceId = sourceMessage.id;
      if (sourceId != null && m.id == sourceId) return true;
      final sourceClientId = sourceMessage.clientId;
      return sourceClientId != null && m.clientId == sourceClientId;
    });
    if (idx >= 0) {
      _notifier.replaceAt(idx, replacement);
    }
    if (replacement.id != null) {
      await ref.read(chatHistoryServiceProvider).updateMessage(replacement);
    }
    scrollToEnd();
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
  ///
  /// On the first open, [ChatMessagesNotifier.loadInitial] reads from disk.
  /// But the notifier is a (non-autoDispose) family provider, so its state
  /// survives after the screen is popped. If a reply lands while the user is
  /// away, the manager persists it to SQLite but the cached in-memory list
  /// goes stale — and `loadInitial` short-circuits on reopen because
  /// `messages` is non-empty. Detect that case (the notifier already finished
  /// its initial load) and force a `reload` from disk so reopening always
  /// reflects the latest persisted history.
  Future<void> loadHistory(String agentId) async {
    final notifier = ref.read(chatMessagesProvider(agentId).notifier);
    final alreadyLoaded =
        !ref.read(chatMessagesProvider(agentId)).initialLoading;
    if (alreadyLoaded) {
      await notifier.reload(manager: manager);
    } else {
      await notifier.loadInitial(manager: manager);
    }
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
