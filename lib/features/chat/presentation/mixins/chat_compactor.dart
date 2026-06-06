import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_history_service.dart';
import '../../data/chat_messages_notifier.dart';
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
  ProviderConfig? resolveProvider();
  Future<ChatMessage> persistMessage(ChatMessage message);
  void scrollToEnd();
  WidgetRef get ref;

  /// Convenience accessor for the notifier.
  ChatMessagesNotifier get _compactNotifier =>
      ref.read(chatMessagesProvider(activeAgentId).notifier);

  /// Current messages snapshot from notifier.
  List<ChatMessage> get _compactMessages =>
      ref.read(chatMessagesProvider(activeAgentId)).messages;

  /// Perform manual /compact.
  Future<void> performCompaction() async {
    final provider = resolveProvider();
    if (provider == null) {
      final msg = ChatMessage(
        role: 'assistant',
        content: s.cannotCompact,
      );
      _compactNotifier.addMessage(msg);
      persistMessage(msg);
      scrollToEnd();
      return;
    }

    final agents = ref.read(agentListProvider);
    final agent = activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == activeAgentId).firstOrNull;
    final maxCtx = agent?.maxContextLength ?? 8191;

    final messages = _compactMessages;
    if (messages.length <= 8) {
      final msg = ChatMessage(
        role: 'assistant',
        content: s.contextAlreadyCompact(
          messages.length,
          ContextCompactor.estimateChatTokens(messages),
          maxCtx,
        ),
      );
      _compactNotifier.addMessage(msg);
      persistMessage(msg);
      scrollToEnd();
      return;
    }

    // Show compacting indicator.
    final loadingMsg = ChatMessage(
      role: 'assistant',
      content: s.compacting,
    );
    _compactNotifier.addMessage(loadingMsg);
    scrollToEnd();

    try {
      final llmConfig = LlmProviderConfig(
        baseUrl: provider.baseUrl,
        apiKey: provider.apiKey,
        model: provider.model,
      );
      final compactor = ContextCompactor();
      final compacted = await compactor.compact(
        messages: _compactMessages,
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

      // Replace messages with compacted set.
      _compactNotifier.replaceAll(compacted);

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
      _compactNotifier.addMessage(doneMsg);
      persistMessage(doneMsg);
      scrollToEnd();
    } catch (e) {
      // Remove loading indicator by reloading current state without it.
      final current = _compactMessages;
      final idx = current.indexWhere((m) => identical(m, loadingMsg));
      if (idx >= 0) _compactNotifier.removeAt(idx);

      final errMsg = ChatMessage(
        role: 'assistant',
        content: s.compactFailed(e.toString()),
      );
      _compactNotifier.addMessage(errMsg);
      persistMessage(errMsg);
      scrollToEnd();
    }
  }
}
