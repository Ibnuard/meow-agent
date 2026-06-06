import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_history_service.dart';
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
  List<ChatMessage> get messagesList;
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

  Future<void> send() async {
    final text = inputController.text.trim();
    if (text.isEmpty || sending) return;
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
      setState(() {
        messagesList.add(userMsg);
        messagesList.add(botMsg);
      });
      inputController.clear();
      persistMessage(userMsg);
      persistMessage(botMsg);
      scrollToEnd();
      return;
    }

    inputController.clear();
    final replyContext = replyToContext;
    if (replyContext != null) {
      setState(() => replyToContext = null);
    }

    // Build the user-visible message with an optional reply quote.
    // The quote is included in both the displayed bubble and the LLM payload
    // so the agent has the full context of what was referenced.
    final messageText = replyContext == null
        ? text
        : buildReplyPayload(replyContext, text);

    // Append attached file names so the chat bubble shows what was sent.
    final attachmentNames =
        chatInputKey.currentState?._attachmentsSnapshot ?? attachments;
    final displayText = attachments.isEmpty
        ? messageText
        : '$messageText\n\n📎 ${attachmentNames.map((a) => a.name).join(", ")}';

    // Collect image paths for thumbnail rendering in the bubble.
    final imageExts = const {'.png','.jpg','.jpeg','.webp','.gif','.bmp','.heic'};
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
    final userMsg = ChatMessage(role: 'user', content: displayText, imagePaths: imgPaths);
    setState(() => messagesList.add(userMsg));
    scrollToEnd();

    // Check context BEFORE calling the runtime. If the threshold was hit
    // and auto-compact is off, surface a warning but DO NOT send the user
    // message to the agent — there is no point because it will fail. The
    // user message is already visible in the chat.
    final blocked = await autoCompactIfNeeded();
    if (blocked) return;

    // Manager persists user msg + final reply, listener reloads history.
    final mgr = ensureManager();
    final recent = messagesList.where((m) => m.id != null).toList();
    mgr.send(
      agentId: activeAgentId,
      userMessage: messageText,
      recentMessages: recent,
      attachments: attachments,
    );
    attachments = [];
    chatInputKey.currentState?.clearAttachments();
    return;
  }
}
