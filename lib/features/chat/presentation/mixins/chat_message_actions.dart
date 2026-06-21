import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/chat_history_service.dart';
import '../../../settings/data/app_language_provider.dart';

/// Message interaction actions: reply, copy, long-press menu.
///
/// All methods are public because Dart library-private identifiers (`_` prefix)
/// are scoped per-file and cannot be called across library boundaries.
mixin ChatMessageActionsMixin<T extends StatefulWidget> on State<T> {
  AppStrings get s;

  List<ChatMessage> get messagesList;
  ChatMessage? get replyToContext;
  set replyToContext(ChatMessage? value);

  Future<ChatMessage> persistMessage(ChatMessage message);
  void scrollToEnd();

  /// Show long-press action sheet for a chat bubble.
  void showMessageActions(ChatMessage msg) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  ctx,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: Text(s.reply),
              onTap: () {
                Navigator.pop(ctx);
                handleReply(msg);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: Text(s.copyText),
              onTap: () {
                Navigator.pop(ctx);
                handleCopy(msg);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void handleCopy(ChatMessage msg) {
    final text = cleanContent(msg.content);
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.copiedToClipboard),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void handleReply(ChatMessage msg) {
    final clean = cleanContent(msg.content);
    if (clean.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.cannotReplyEmpty),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() => replyToContext = msg);
    // Auto-focus the input.
    FocusScope.of(context).requestFocus(FocusNode());
  }

  void cancelReply() {
    setState(() => replyToContext = null);
  }

  /// Strip all sentinels (confirmation, reply-quote opening + closing) and
  /// trim whitespace. Used everywhere we need the "clean" user-visible text.
  static String cleanContent(String raw) {
    return raw
        .replaceAll(
          RegExp(
            r'\[\[REPLY_QUOTE:[^\]]+\]\].*?\[\[/REPLY_QUOTE\]\]\n?',
            dotAll: true,
          ),
          '',
        )
        .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
        .replaceAll('[[CONFIRMATION_REQUIRED]]', '')
        .trim();
  }

  /// Wrap user text with a quote sentinel so the LLM and the UI both see
  /// what's being referenced. Sentinels are stripped from display by [_Bubble]
  /// which renders the quote as a styled inline chip above the user's text.
  String buildReplyPayload(ChatMessage quoted, String userText) {
    final quotedText = cleanContent(quoted.content);
    // Truncate very long quotes so we don't blow up context.
    final truncated = quotedText.length > 280
        ? '${quotedText.substring(0, 280)}…'
        : quotedText;
    final role = quoted.role == 'user' ? 'You' : 'Agent';
    return '[[REPLY_QUOTE:$role]]$truncated[[/REPLY_QUOTE]]\n$userText';
  }
}
