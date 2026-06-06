import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_history_service.dart';
import '../../data/chat_messages_notifier.dart';
import '../../data/chat_runtime_manager.dart';
import '../../../../services/agent_runtime/runtime_models.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../../../app/router.dart';
import '../../../providers/data/provider_config.dart';
import '../../../agents/data/agent_repository.dart';

/// Message sending logic.
mixin ChatSendHandlerMixin<T extends StatefulWidget> on State<T> {
  AppStrings get s;
  String get activeAgentId;
  ChatMessage? get replyToContext;
  set replyToContext(ChatMessage? value);
  List<AttachedFile> get attachments;
  set attachments(List<AttachedFile> value);
  dynamic get chatInputKey;
  TextEditingController get inputController;
  bool get sending;
  ProviderConfig? resolveProvider();
  ChatRuntimeManager ensureManager();
  Future<bool> autoCompactIfNeeded();
  Future<ChatMessage> persistMessage(ChatMessage message);
  void scrollToEnd();
  void handleCommand(String text);
  String buildReplyPayload(ChatMessage quoted, String userText);
  WidgetRef get ref;

  /// Convenience accessor for the active agent's message notifier.
  ChatMessagesNotifier get _msgNotifier =>
      ref.read(chatMessagesProvider(activeAgentId).notifier);

  Future<void> send() async {
    final text = inputController.text.trim();
    if (text.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();

    // Slash commands handled locally.
    if (text.startsWith('/')) {
      handleCommand(text);
      return;
    }

    final provider = resolveProvider();
    if (provider == null || !provider.isComplete) {
      final agents = ref.read(agentListProvider);
      final agent = activeAgentId == 'default'
          ? (agents.isNotEmpty ? agents.first : null)
          : agents.where((a) => a.id == activeAgentId).firstOrNull;
      final agentName = agent?.name ?? activeAgentId;
      final userMsg = ChatMessage(role: 'user', content: text);
      final botMsg = ChatMessage(
        role: 'assistant',
        content: '️ ${s.providerMissingBody(agentName)}',
        actions: [
          ResultAction(
            label: s.manageProvidersAction,
            icon: 'dns_outlined',
            type: 'navigate',
            target: AppRoutes.providerList,
          ),
        ],
      );
      _msgNotifier.addMessage(userMsg);
      _msgNotifier.addMessage(botMsg);
      inputController.clear();
      persistMessage(userMsg);
      persistMessage(botMsg);
      scrollToEnd();
      return;
    }

    inputController.clear();
    final replyContext = replyToContext;
    if (replyContext != null) {
      replyToContext = null;
    }

    // Build the user-visible message with an optional reply quote.
    // The quote is included in both the displayed bubble and the LLM payload
    // so the agent has the full context of what was referenced.
    final messageText = replyContext == null
        ? text
        : buildReplyPayload(replyContext, text);

    final displayText = attachments.isEmpty
        ? messageText
        : '$messageText\n\n📎 ${attachments.map((a) => a.name).join(", ")}';

    // Collect image paths for thumbnail rendering in the bubble.
    final imageExts = const {
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
      '.gif',
      '.bmp',
      '.heic',
    };
    final imgPaths = attachments
        .where((a) {
          final dot = a.path.lastIndexOf('.');
          if (dot < 0) return false;
          return imageExts.contains(a.path.substring(dot).toLowerCase());
        })
        .map((a) => a.path)
        .toList();

    // Optimistically show the user message immediately — it always lands
    // in history regardless of context exhaustion.
    final userMsg = ChatMessage.outgoing(
      content: displayText,
      imagePaths: imgPaths,
    );
    final clientId = userMsg.clientId!;
    _msgNotifier.addMessage(userMsg);
    scrollToEnd();

    // Snapshot attachments and clear the input UI now so the chat composer
    // resets instantly. The actual send happens after the next frame paints.
    final attachmentsSnapshot = List<AttachedFile>.from(attachments);
    attachments = [];
    chatInputKey.currentState?.clearAttachments();

    // Defer ALL heavy work to AFTER this frame paints. Without this, the
    // synchronous prelude inside ChatRuntimeManager.send() (provider resolve,
    // disk write of the user message, isRunning state flip that triggers a
    // full ChatScreen setState via the manager listener) executes via
    // microtasks before Flutter gets a chance to render the optimistic
    // bubble — causing a perceptible freeze/bounce on tap. WhatsApp-style
    // instant feedback requires forcing a paint between the optimistic add
    // and the heavy work.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      late ChatMessage persistedUserMsg;
      try {
        persistedUserMsg = await persistMessage(userMsg);
        if (!mounted) return;
        _msgNotifier.replaceByClientId(clientId, persistedUserMsg);
      } catch (e) {
        if (!mounted) return;
        _msgNotifier.updateDeliveryStatus(
          clientId,
          ChatMessageDeliveryStatus.failed,
          errorMessage: e.toString(),
        );
        return;
      }

      // Check context BEFORE calling the runtime. If the threshold was hit
      // and auto-compact is off, surface a warning but DO NOT send the user
      // message to the agent — there is no point because it will fail. The
      // user message is already visible in the chat.
      final blocked = await autoCompactIfNeeded();
      if (blocked) {
        final failedMsg = persistedUserMsg.copyWith(
          deliveryStatus: ChatMessageDeliveryStatus.failed,
        );
        _msgNotifier.replaceByClientId(clientId, failedMsg);
        await ref.read(chatHistoryServiceProvider).updateMessage(failedMsg);
        return;
      }

      final acceptedUserMsg = persistedUserMsg.copyWith(
        deliveryStatus: ChatMessageDeliveryStatus.sent,
        clearErrorMessage: true,
      );
      _msgNotifier.replaceByClientId(clientId, acceptedUserMsg);
      await ref.read(chatHistoryServiceProvider).updateMessage(acceptedUserMsg);

      // Manager processes this persisted user message and publishes persisted
      // assistant replies back through its lightweight session payload.
      final mgr = ensureManager();
      final messages = ref.read(chatMessagesProvider(activeAgentId)).messages;
      final recent = messages
          .where((m) => m.id != null && m.clientId != clientId)
          .toList();
      mgr.send(
        agentId: activeAgentId,
        userMessage: messageText,
        recentMessages: recent,
        attachments: attachmentsSnapshot,
        persistedUserMessage: acceptedUserMsg,
      );
    });
    return;
  }
}
