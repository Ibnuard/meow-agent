import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_history_service.dart';
import '../../../../services/agent_runtime/context_compactor.dart';
import '../../../../services/workspace/workspace_file_service.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../../settings/data/llm_provider_config.dart';
import '../../../providers/data/provider_config.dart';
import '../../../agents/data/agent_repository.dart';

/// Context compaction logic (manual and auto).
mixin ChatCompactorMixin<T extends StatefulWidget> on State<T> {
  AppStrings get s;
  String get activeAgentId;
  List<ChatMessage> get messagesList;
  Map<String, List<ChatMessage>> get messagesByAgent;
  ProviderConfig? resolveProvider();
  Future<ChatMessage> persistMessage(ChatMessage message);
  void scrollToEnd();
  WidgetRef get ref;

  /// Perform manual /compact.
  Future<void> performCompaction() async {
    final provider = resolveProvider();
    if (provider == null) {
      final msg = ChatMessage(
        role: 'assistant',
        content: s.cannotCompact,
      );
      setState(() => messagesList.add(msg));
      persistMessage(msg);
      scrollToEnd();
      return;
    }

    final agents = ref.read(agentListProvider);
    final agent = activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == activeAgentId).firstOrNull;
    final maxCtx = agent?.maxContextLength ?? 8191;

    if (messagesList.length <= 8) {
      final msg = ChatMessage(
        role: 'assistant',
        content: s.contextAlreadyCompact(
          messagesList.length,
          ContextCompactor.estimateChatTokens(messagesList),
          maxCtx,
        ),
      );
      setState(() => messagesList.add(msg));
      persistMessage(msg);
      scrollToEnd();
      return;
    }

    // Show compacting indicator.
    final loadingMsg = ChatMessage(
      role: 'assistant',
      content: s.compacting,
    );
    setState(() => messagesList.add(loadingMsg));
    scrollToEnd();

    try {
      final llmConfig = LlmProviderConfig(
        baseUrl: provider.baseUrl,
        apiKey: provider.apiKey,
        model: provider.model,
      );
      final compactor = ContextCompactor();
      final compacted = await compactor.compact(
        messages: messagesList,
        config: llmConfig,
        keepRecent: 6,
      );

      // Clear old history and replace with compacted.
      await ref.read(chatHistoryServiceProvider).clear(activeAgentId);
      for (final msg in compacted) {
        await ref
            .read(chatHistoryServiceProvider)
            .addMessage(activeAgentId, msg);
      }

      // Remove loading indicator and reload.
      setState(() {
        messagesList.remove(loadingMsg);
        messagesByAgent[activeAgentId] = compacted;
      });

      // Write summary snapshot to workspace.
      final summaryText = compacted.first.content;
      final agentName = agent?.name ?? '';
      if (agentName.isNotEmpty) {
        WorkspaceFileService.writeSummarySnapshot(agentName, summaryText);
      }

      final doneMsg = ChatMessage(
        role: 'assistant',
        content: s.contextCompacted(
          compacted.length,
          ContextCompactor.estimateChatTokens(compacted),
        ),
      );
      setState(() => messagesList.add(doneMsg));
      persistMessage(doneMsg);
      scrollToEnd();
    } catch (e) {
      setState(() => messagesList.remove(loadingMsg));
      final errMsg = ChatMessage(
        role: 'assistant',
        content: s.compactFailed(e.toString()),
      );
      setState(() => messagesList.add(errMsg));
      persistMessage(errMsg);
      scrollToEnd();
    }
  }

  /// Auto-compact if context exceeds 80% threshold.
  ///
  /// Returns `true` when the send was BLOCKED (auto-compact off + context full),
  /// and the caller should not proceed with the user's request.
  Future<bool> autoCompactIfNeeded() async {
    final agents = ref.read(agentListProvider);
    final agent = activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == activeAgentId).firstOrNull;
    final maxCtx = agent?.maxContextLength ?? 8191;

    if (!ContextCompactor.needsCompaction(
      messages: messagesList,
      maxContextLength: maxCtx,
    )) {
      return false;
    }

    if (agent?.autoCompact == false) {
      final msg = ChatMessage(
        role: 'assistant',
        content: s.contextExhausted(agent!.maxContextLength),
      );
      setState(() => messagesList.add(msg));
      persistMessage(msg);
      return true;
    }

    final provider = resolveProvider();
    if (provider == null) return false;

    try {
      final llmConfig = LlmProviderConfig(
        baseUrl: provider.baseUrl,
        apiKey: provider.apiKey,
        model: provider.model,
      );
      final compactor = ContextCompactor();
      final compacted = await compactor.compact(
        messages: messagesList,
        config: llmConfig,
        keepRecent: 8,
      );

      // Persist compacted history.
      await ref.read(chatHistoryServiceProvider).clear(activeAgentId);
      for (final msg in compacted) {
        await ref
            .read(chatHistoryServiceProvider)
            .addMessage(activeAgentId, msg);
      }

      setState(() {
        messagesByAgent[activeAgentId] = compacted;
      });

      // Notify user.
      final infoMsg = ChatMessage(
        role: 'assistant',
        content: s.autoCompacted(compacted.length),
      );
      setState(() => messagesList.add(infoMsg));
      persistMessage(infoMsg);
      return false;
    } catch (_) {
      // Silent fail for auto-compact — don't block the user's message.
    }
    return false;
  }
}
