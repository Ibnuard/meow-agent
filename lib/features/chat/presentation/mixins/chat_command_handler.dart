import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_history_service.dart';
import '../../../../services/agent_runtime/runtime_models.dart';
import '../../../../services/llm/openai_compatible_client.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../../providers/data/provider_repository.dart';
import '../../../agents/data/agent_repository.dart';

/// Slash command handling.
mixin ChatCommandHandlerMixin<T extends StatefulWidget> on State<T> {
  AppStrings get s;
  String get activeAgentId;
  List<ChatMessage> get messagesList;
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

  Future<void> handleCommand(String text) async {
    final cmd = text.split(' ').first.toLowerCase();
    inputController.clear();

    // Show the slash command itself in the chat history so the user can see
    // what they ran (and scroll back to it later). For /clear we deliberately
    // skip persistence because the next step wipes the agent's history.
    final userMsg = ChatMessage(role: 'user', content: text);
    setState(() => messagesList.add(userMsg));
    if (cmd != '/clear') {
      persistMessage(userMsg);
    }
    scrollToEnd();

    String response;
    bool shouldPersist = true;

    switch (cmd) {
      case '/clear':
        await ref.read(chatHistoryServiceProvider).clear(activeAgentId);
        // Note: messagesByAgent and fullyLoaded need to be accessible
        // This will be handled by the history manager mixin
        OpenAiCompatibleClient.clearUsageRecords();
        setState(() {});
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
        // Soft reset: clear context measurement so the next message is a fresh
        // slate, but keep the visible chat history intact.
        OpenAiCompatibleClient.clearUsageRecords();
        response = s.contextReset;
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
      case '/cron':
        response = s.cronNoJobs;
      case '/log':
        response = await buildRuntimeLogReport();
      case '/clearlog':
        response = await clearRuntimeLog();
      default:
        response = s.unknownCommand(cmd);
    }

    final botMsg = ChatMessage(role: 'assistant', content: response);
    setState(() => messagesList.add(botMsg));
    if (shouldPersist) await persistMessage(botMsg);
    scrollToEnd();
  }

  String buildCommandHelp(bool debugMode) {
    final buffer = StringBuffer()
      ..writeln(s.helpAvailableCommands)
      ..writeln('- /clear - ${s.helpSlashClear}')
      ..writeln('- /help - ${s.helpSlashHelp}')
      ..writeln('- /status - ${s.helpSlashStatus}')
      ..writeln('- /context - ${s.helpSlashContext}')
      ..writeln('- /reset - ${s.helpSlashReset}')
      ..writeln('- /model - ${s.helpSlashModel}')
      ..writeln('- /set-model - ${s.helpSlashSetModel}')
      ..writeln('- /compact - ${s.helpSlashCompact}')
      ..write('- /cron - ${s.helpSlashCron}');
    if (debugMode) {
      buffer
        ..writeln()
        ..writeln('- /log - ${s.helpSlashLog}')
        ..write('- /clearlog - ${s.helpSlashClearlog}');
    }
    return buffer.toString();
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
      botMsg = ChatMessage(
        role: 'assistant',
        content: s.noProviderOrModel,
      );
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

    setState(() => messagesList.add(botMsg));
    final persisted = await persistMessage(botMsg);
    if (!mounted) return;
    setState(() {
      final idx = messagesList.indexWhere((m) => identical(m, botMsg));
      if (idx >= 0) messagesList[idx] = persisted;
    });
    scrollToEnd();
  }
}
