import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_history_service.dart';
import '../../data/chat_messages_notifier.dart';
import '../../data/chat_runtime_manager.dart';
import '../../data/chat_session_service.dart';
import '../../data/token_usage_service.dart';
import '../../../../services/agent_runtime/context_compactor.dart';
import '../../../../services/agent_runtime/runtime_engine.dart';
import '../../../../services/agent_runtime/runtime_models.dart';
import '../../../../services/llm/openai_compatible_client.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../../providers/data/provider_repository.dart';
import '../../../agents/data/agent_repository.dart';
import '../../../modules/workflows/workflow_repository.dart';

/// Slash command handling.
mixin ChatCommandHandlerMixin<T extends StatefulWidget> on State<T> {
  AppStrings get s;
  String get activeAgentId;
  TextEditingController get inputController;
  bool get debugMode;
  Future<void> performCompaction();
  Future<String> buildContextReport();
  String buildStatusInfo();
  Future<String> buildRuntimeLogReport();
  Future<String> clearRuntimeLog();
  Future<ChatMessage> persistMessage(ChatMessage message);
  void scrollToEnd();
  WidgetRef get ref;

  /// Convenience accessor for the notifier.
  ChatMessagesNotifier get _cmdNotifier =>
      ref.read(chatMessagesProvider(activeAgentId).notifier);

  Future<void> handleCommand(String text) async {
    final cmd = text.split(' ').first.toLowerCase();
    inputController.clear();

    // Show the slash command itself in the chat history so the user can see
    // what they ran. State-resetting commands are deliberately not persisted:
    // they should never become the next LLM context.
    final userMsg = ChatMessage(role: 'user', content: text);
    _cmdNotifier.addMessage(userMsg);
    if (!_isEphemeralCommand(cmd)) {
      await persistMessage(userMsg);
    }
    scrollToEnd();

    String response;
    var shouldPersist = true;

    switch (cmd) {
      case '/clear':
        await _resetRuntimeState();
        await ref.read(chatHistoryServiceProvider).clear(activeAgentId);
        _cmdNotifier.clear();
        await ref
            .read(chatSessionServiceProvider)
            .startNewSession(activeAgentId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(s.chatHistoryCleared),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        return;
      case '/help':
        response = buildCommandHelp(debugMode);
      case '/reset':
        // Same session id, clean persisted history/context for that session.
        // The visible transcript stays in memory so the user is not jolted.
        await _resetRuntimeState();
        final sessionId = ref
            .read(chatSessionServiceProvider)
            .currentSessionId(activeAgentId);
        await ref
            .read(chatHistoryServiceProvider)
            .clearSession(activeAgentId, sessionId);
        response = s.contextReset;
        shouldPersist = false;
      case '/new-session':
        final previousId = ref
            .read(chatSessionServiceProvider)
            .currentSessionId(activeAgentId);
        await _resetRuntimeState();
        final nextId = await ref
            .read(chatSessionServiceProvider)
            .startNewSession(activeAgentId);
        response = s.newSessionStartedWithResume(nextId, previousId);
        shouldPersist = false;
      case '/resume':
        await _handleResume(text);
        return;
      case '/model':
        final agents = ref.read(agentListProvider);
        final providers = ref.read(providerListProvider).value ?? [];
        final agent = activeAgentId == 'default'
            ? (agents.isNotEmpty ? agents.first : null)
            : agents.where((a) => a.id == activeAgentId).firstOrNull;
        final provider = agent != null
            ? providers.where((p) => p.id == agent.providerId).firstOrNull
            : null;
        if (provider != null) {
          final agentModel = agent?.model ?? '';
          final modelInfo = agentModel.isNotEmpty
              ? '\n• Model: ${provider.effectiveModel(agentModel)}'
              : '\n• Model: (provider default)';
          response =
              ' Model Info:\n'
              '• Provider: ${provider.nickname}$modelInfo\n'
              '• Endpoint: ${provider.baseUrl}';
        } else {
          response = s.noProviderConnected;
        }
      case '/set-model':
        await showModelsCommandBubble();
        return;
      case '/compact':
        await performCompaction();
        return;
      case '/status':
        response = buildStatusInfo();
      case '/context':
        response = await buildContextReport();
      case '/workflow':
        response = await buildWorkflowList();
        break;
      case '/log':
        response = await buildRuntimeLogReport();
      case '/clearlog':
        response = await clearRuntimeLog();
      default:
        response = s.unknownCommand(cmd);
    }

    final botMsg = ChatMessage(role: 'assistant', content: response);
    _cmdNotifier.addMessage(botMsg);
    if (shouldPersist) await persistMessage(botMsg);
    scrollToEnd();
  }

  bool _isEphemeralCommand(String cmd) =>
      const {'/clear', '/reset', '/new-session', '/resume'}.contains(cmd);

  Future<void> _resetRuntimeState() async {
    await ref
        .read(chatRuntimeManagerProvider)
        .resetLocalStateForFreshSession(activeAgentId);
    await ref.read(agentRuntimeEngineProvider).resetAgentState(activeAgentId);
    OpenAiCompatibleClient.clearUsageRecords();
    ContextCompactor.clearPersistedPeak();
    await ref.read(tokenUsageServiceProvider).delete(activeAgentId);
  }

  String buildCommandHelp(bool debugMode) {
    final buffer = StringBuffer()
      ..writeln(s.helpAvailableCommands)
      ..writeln(s.helpCommandHint)
      ..writeln()
      ..writeln(_formatHelpCommand('🧹', '/clear', s.helpSlashClear))
      ..writeln(_formatHelpCommand('✨', '/help', s.helpSlashHelp))
      ..writeln(_formatHelpCommand('📊', '/status', s.helpSlashStatus))
      ..writeln(_formatHelpCommand('🧠', '/context', s.helpSlashContext))
      ..writeln(_formatHelpCommand('🔄', '/reset', s.helpSlashReset))
      ..writeln(_formatHelpCommand('✨', '/new-session', s.helpSlashNewSession))
      ..writeln(_formatHelpCommand('↩️', '/resume', s.helpSlashResume))
      ..writeln(_formatHelpCommand('🤖', '/model', s.helpSlashModel))
      ..writeln(_formatHelpCommand('🎛️', '/set-model', s.helpSlashSetModel))
      ..writeln(_formatHelpCommand('🪶', '/compact', s.helpSlashCompact))
      ..write(_formatHelpCommand('⚙️', '/workflow', s.helpSlashWorkflow));
    if (debugMode) {
      buffer
        ..writeln()
        ..writeln(_formatHelpCommand('🧾', '/log', s.helpSlashLog))
        ..write(_formatHelpCommand('🧽', '/clearlog', s.helpSlashClearlog));
    }
    return buffer.toString();
  }

  String _formatHelpCommand(String icon, String command, String description) {
    return '$icon  $command\n   $description';
  }

  Future<void> _postTransientCommandBubble(String content) async {
    final botMsg = ChatMessage(role: 'assistant', content: content);
    _cmdNotifier.addMessage(botMsg);
    scrollToEnd();
  }

  /// Handle `/resume {id}`. With no id, lists available sessions. With a valid
  /// id, switches the active session and hard-resets runtime state so the
  /// resumed context starts clean.
  Future<void> _handleResume(String text) async {
    final parts = text.trim().split(RegExp(r'\s+'));
    final requestedId = parts.length > 1 ? parts[1].trim() : '';
    final history = ref.read(chatHistoryServiceProvider);
    final sessions = await history.listSessions(activeAgentId);

    if (requestedId.isEmpty) {
      final others = sessions
          .where((s) => s.messageCount > 0)
          .toList(growable: false);
      final String body;
      if (others.isEmpty) {
        body = s.resumeUsageNoSessions;
      } else {
        final buf = StringBuffer()..writeln(s.resumeUsageHeader(others.length));
        for (final session in others) {
          final preview = session.preview.trim();
          final shortPreview = preview.length > 48
              ? '${preview.substring(0, 48)}…'
              : preview;
          buf.writeln(
            '• ${session.sessionId}'
            '${shortPreview.isEmpty ? '' : ' — $shortPreview'}',
          );
        }
        body = buf.toString().trimRight();
      }
      await _postTransientCommandBubble(body);
      return;
    }

    final exists = sessions.any((s) => s.sessionId == requestedId);
    if (!exists) {
      await _postTransientCommandBubble(s.sessionNotFound(requestedId));
      return;
    }

    await _resetRuntimeState();
    await ref
        .read(chatSessionServiceProvider)
        .setCurrentSession(activeAgentId, requestedId);
    await _postTransientCommandBubble(s.sessionResumed(requestedId));
  }

  Future<void> showModelsCommandBubble() async {
    final agents = ref.read(agentListProvider);
    final providers = ref.read(providerListProvider).value ?? [];
    final agent = activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == activeAgentId).firstOrNull;
    final provider = agent == null
        ? null
        : providers.where((p) => p.id == agent.providerId).firstOrNull;

    final ChatMessage botMsg;
    if (agent == null || provider == null || provider.models.isEmpty) {
      botMsg = ChatMessage(role: 'assistant', content: s.noProviderOrModel);
    } else {
      final selected = provider.effectiveModel(agent.model);
      botMsg = ChatMessage(
        role: 'assistant',
        content: s.chooseModelPrompt(selected),
        actions: [
          for (final model in provider.models)
            ResultAction(
              label: model == selected ? '$model ✓' : model,
              icon: provider.visionModels.contains(model)
                  ? 'visibility_rounded'
                  : 'memory_rounded',
              type: 'select_model',
              target: model,
              params: {'providerId': provider.id},
            ),
        ],
      );
    }

    _cmdNotifier.addMessage(botMsg);
    final persisted = await persistMessage(botMsg);
    if (!mounted) return;
    // Replace the temporary message with the persisted version (which has an ID).
    final messages = ref.read(chatMessagesProvider(activeAgentId)).messages;
    final idx = messages.indexWhere((m) => identical(m, botMsg));
    if (idx >= 0) {
      _cmdNotifier.replaceAt(idx, persisted);
    }
    scrollToEnd();
  }

  /// Build a human-readable list of workflows assigned to the active agent.
  Future<String> buildWorkflowList() async {
    final repo = ref.read(workflowRepositoryProvider);
    final allWorkflows = await repo.list(agentId: activeAgentId);

    if (allWorkflows.isEmpty) {
      return s.noWorkflows(activeAgentId);
    }

    final buf = StringBuffer()
      ..writeln(s.workflowListHeader(allWorkflows.length));

    for (final w in allWorkflows) {
      final status = w.enabled ? '✅' : '⏸️';
      final trigger = w.trigger.summary;
      final steps = w.isChained ? ' (${w.steps.length} steps)' : '';
      buf.writeln('$status ${w.title}$steps — $trigger');
    }

    return buf.toString();
  }
}
