import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../../../app/theme.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../../../services/agent_runtime/runtime_models.dart';
import '../../../../services/llm/llm_error_mapper.dart';
import '../../data/chat_history_service.dart';

/// Reusable chat bubble for Meow Agent.
///
/// Chat list bubbles always render as plain text to keep scrolling cheap.
/// Markdown is rendered only in the on-demand detail sheet.
class MeowBubble extends StatelessWidget {
  const MeowBubble({
    super.key,
    required this.msg,
    required this.strings,
    this.onConfirmAction,
    this.onActionTap,
    this.onLongPress,
  });

  final ChatMessage msg;
  final AppStrings strings;
  final void Function(String action)? onConfirmAction;
  final void Function(ResultAction action, ChatMessage sourceMessage)?
  onActionTap;
  final VoidCallback? onLongPress;

  static final _quoteRegExp = RegExp(
    r'\[\[REPLY_QUOTE:([^\]]+)\]\](.*?)\[\[/REPLY_QUOTE\]\]\n?',
    dotAll: true,
  );
  static const int _longMessageChars = 600;
  static const int _longMessageLines = 20;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final isUser = msg.role == 'user';
    final isConfirmation = msg.content.contains('[[CONFIRMATION_REQUIRED]]');

    String? quoteRole;
    String? quoteText;
    var rawContent = msg.content;
    // Strip provider-error sentinel (transient connection failure marker).
    rawContent = LlmErrorMapper.stripSentinel(rawContent);
    final quoteMatch = _quoteRegExp.firstMatch(rawContent);
    if (quoteMatch != null) {
      quoteRole = quoteMatch.group(1);
      quoteText = quoteMatch.group(2)?.trim();
      rawContent = rawContent.replaceFirst(quoteMatch.group(0)!, '');
    }
    final displayContent = rawContent
        .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
        .replaceAll('[[CONFIRMATION_REQUIRED]]', '')
        .trim();

    final hasNothingToShow =
        displayContent.isEmpty &&
        (quoteText == null || quoteText.isEmpty) &&
        msg.actions.isEmpty &&
        !isConfirmation;
    if (hasNothingToShow) return const SizedBox.shrink();

    final hasMarkdown = !isUser && _looksLikeMarkdown(displayContent);
    final isLong = !isUser && _isLongContent(displayContent);
    final maxWidth = MediaQuery.of(context).size.width * 0.78;

    final container = Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isUser ? cs.primary : extras.card,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isUser ? 16 : 4),
          bottomRight: Radius.circular(isUser ? 4 : 16),
        ),
        border: isUser ? null : Border.all(color: extras.subtleBorder),
      ),
      child: _PlainLayout(
        content: displayContent,
        quoteRole: quoteRole,
        quoteText: quoteText,
        isUser: isUser,
        isConfirmation: isConfirmation,
        strings: strings,
        msg: msg,
        hasMarkdown: hasMarkdown,
        isLong: isLong,
        onConfirmAction: onConfirmAction,
        onActionTap: onActionTap,
        onReplyFromSheet: onLongPress,
      ),
    );

    final shouldMeasureIntrinsic = isUser || (!hasMarkdown && !isLong);
    final constrained = ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: isUser ? 72 : 0,
        maxWidth: maxWidth,
      ),
      child: shouldMeasureIntrinsic
          ? IntrinsicWidth(child: container)
          : container,
    );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: onLongPress != null
          ? GestureDetector(onLongPress: onLongPress, child: constrained)
          : constrained,
    );
  }

  static bool _looksLikeMarkdown(String content) {
    if (content.isEmpty) return false;
    if (content.contains('```') ||
        content.contains('**') ||
        content.contains('__') ||
        content.contains('`') ||
        content.contains(RegExp(r'\[[^\]]+\]\([^)]+\)'))) {
      return true;
    }
    return content.contains(
      RegExp(r'(^|\n)\s{0,3}(#{1,6}\s|[-*+]\s|\d+\.\s|>\s|\|)'),
    );
  }

  static bool _isLongContent(String content) {
    return content.length > _longMessageChars ||
        '\n'.allMatches(content).length > _longMessageLines;
  }
}

String formatBubbleTime(BuildContext context, DateTime dt) {
  final use24 = MediaQuery.of(context).alwaysUse24HourFormat;
  final tod = TimeOfDay.fromDateTime(dt.toLocal());
  return MaterialLocalizations.of(
    context,
  ).formatTimeOfDay(tod, alwaysUse24HourFormat: use24);
}

class _PlainLayout extends StatelessWidget {
  const _PlainLayout({
    required this.content,
    required this.quoteRole,
    required this.quoteText,
    required this.isUser,
    required this.isConfirmation,
    required this.strings,
    required this.msg,
    required this.hasMarkdown,
    required this.isLong,
    required this.onConfirmAction,
    required this.onActionTap,
    required this.onReplyFromSheet,
  });

  final String content;
  final String? quoteRole;
  final String? quoteText;
  final bool isUser;
  final bool isConfirmation;
  final AppStrings strings;
  final ChatMessage msg;
  final bool hasMarkdown;
  final bool isLong;
  final void Function(String action)? onConfirmAction;
  final void Function(ResultAction action, ChatMessage sourceMessage)?
  onActionTap;
  final VoidCallback? onReplyFromSheet;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final s = strings;
    final textStyle = TextStyle(
      color: isUser ? cs.onPrimary : cs.onSurface,
      fontSize: 14,
      height: 1.4,
    );
    final timeStyle = TextStyle(
      fontSize: 10,
      color: (isUser ? Colors.white : cs.onSurfaceVariant).withValues(
        alpha: 0.7,
      ),
    );
    final hasActionControls =
        (isConfirmation && onConfirmAction != null) ||
        (!isUser && msg.actions.isNotEmpty && onActionTap != null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (quoteText != null && quoteText!.isNotEmpty) ...[
          _QuoteChip(role: quoteRole ?? '', text: quoteText!, isUser: isUser),
        ],
        if (isUser && msg.imagePaths.isNotEmpty) ...[
          _ImageThumbnails(paths: msg.imagePaths),
          const SizedBox(height: 6),
        ],
        Text(
          content,
          maxLines: isLong ? 12 : null,
          overflow: isLong ? TextOverflow.ellipsis : TextOverflow.visible,
          style: textStyle,
        ),
        if (!isUser && (isLong || hasMarkdown)) ...[
          const SizedBox(height: 8),
          _BubbleContentAction(
            icon: isLong
                ? Icons.keyboard_arrow_down_rounded
                : Icons.article_outlined,
            label: isLong ? s.seeMore : s.viewMarkdown,
            onTap: () => _showMarkdownSheet(
              context,
              content: content,
              renderMarkdown: hasMarkdown,
              s: s,
              onReply: onReplyFromSheet,
            ),
          ),
        ],
        if (isConfirmation && onConfirmAction != null) ...[
          const SizedBox(height: 12),
          _ConfirmRow(s: s, onAction: onConfirmAction!),
        ],
        if (!isUser && msg.actions.isNotEmpty && onActionTap != null) ...[
          const SizedBox(height: 10),
          _ActionRow(actions: msg.actions, msg: msg, onTap: onActionTap!),
        ],
        SizedBox(height: hasActionControls ? 6 : 3),
        Align(
          alignment: Alignment.bottomRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(formatBubbleTime(context, msg.timestamp), style: timeStyle),
              if (isUser) ...[
                const SizedBox(width: 4),
                _DeliveryMark(status: msg.deliveryStatus),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _DeliveryMark extends StatelessWidget {
  const _DeliveryMark({required this.status});

  final ChatMessageDeliveryStatus status;

  @override
  Widget build(BuildContext context) {
    final icon = switch (status) {
      ChatMessageDeliveryStatus.pending ||
      ChatMessageDeliveryStatus.sending => Icons.schedule_rounded,
      ChatMessageDeliveryStatus.sent => Icons.done_rounded,
      ChatMessageDeliveryStatus.failed => Icons.error_outline_rounded,
    };
    final color = status == ChatMessageDeliveryStatus.failed
        ? Colors.redAccent
        : Colors.white.withValues(alpha: 0.76);
    return Icon(icon, size: 12, color: color);
  }
}

class _BubbleContentAction extends StatelessWidget {
  const _BubbleContentAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: cs.primary),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _showMarkdownSheet(
  BuildContext context, {
  required String content,
  required bool renderMarkdown,
  required AppStrings s,
  VoidCallback? onReply,
}) {
  final cs = Theme.of(context).colorScheme;
  final extras = context.extras;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: extras.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _SheetAction(
                  icon: Icons.copy_rounded,
                  label: s.copyTooltip,
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: content));
                    Navigator.of(ctx).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(s.copied),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                ),
                if (onReply != null) ...[
                  const SizedBox(width: 12),
                  _SheetAction(
                    icon: Icons.reply_rounded,
                    label: s.reply,
                    onTap: () {
                      Navigator.of(ctx).pop();
                      onReply();
                    },
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SizedBox(
                width: double.infinity,
                child: renderMarkdown
                    ? GptMarkdown(
                        content,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 14,
                          height: 1.5,
                        ),
                      )
                    : Text(
                        content,
                        textAlign: TextAlign.left,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
              ),
            ),
          ),
          SizedBox(height: 16 + MediaQuery.of(ctx).padding.bottom),
        ],
      ),
    ),
  );
}

class _QuoteChip extends StatelessWidget {
  const _QuoteChip({
    required this.role,
    required this.text,
    required this.isUser,
  });

  final String role;
  final String text;
  final bool isUser;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isUser
            ? Colors.white.withValues(alpha: 0.18)
            : cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(
            color: isUser ? Colors.white70 : cs.primary,
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            role,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: isUser ? Colors.white : cs.primary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: isUser ? Colors.white70 : cs.onSurfaceVariant,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageThumbnails extends StatelessWidget {
  const _ImageThumbnails({required this.paths});

  final List<String> paths;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final p in paths)
          GestureDetector(
            onTap: () => _showImagePreview(context, p),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(p),
                width: 48,
                height: 48,
                cacheWidth: 96,
                cacheHeight: 96,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.broken_image_rounded,
                    size: 18,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showImagePreview(BuildContext context, String path) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(File(path), fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}

class _ConfirmRow extends StatelessWidget {
  const _ConfirmRow({required this.s, required this.onAction});

  final AppStrings s;
  final void Function(String action) onAction;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _ConfirmChip(
          label: s.accept,
          icon: Icons.check_rounded,
          color: cs.primary,
          onTap: () => onAction('accept'),
        ),
        _ConfirmChip(
          label: s.always,
          icon: Icons.done_all_rounded,
          color: Colors.green,
          onTap: () => onAction('always_accept'),
        ),
        _ConfirmChip(
          label: s.reject,
          icon: Icons.close_rounded,
          color: Colors.redAccent,
          onTap: () => onAction('reject'),
        ),
      ],
    );
  }
}

class _ConfirmChip extends StatelessWidget {
  const _ConfirmChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends ConsumerWidget {
  const _ActionRow({
    required this.actions,
    required this.msg,
    required this.onTap,
  });

  final List<ResultAction> actions;
  final ChatMessage msg;
  final void Function(ResultAction action, ChatMessage sourceMessage) onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: actions
          .map(
            (a) => InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => onTap(a, msg),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_iconFor(a.icon), size: 16, color: cs.primary),
                    const SizedBox(width: 6),
                    Text(
                      a.label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  IconData _iconFor(String name) {
    switch (name) {
      case 'calendar_month_rounded':
        return Icons.calendar_month_rounded;
      case 'note_alt_rounded':
        return Icons.note_alt_rounded;
      case 'folder_open_rounded':
        return Icons.folder_open_rounded;
      case 'open_in_new_rounded':
        return Icons.open_in_new_rounded;
      case 'add_rounded':
        return Icons.add_rounded;
      case 'extension_rounded':
        return Icons.extension_rounded;
      case 'dns_outlined':
        return Icons.dns_outlined;
      case 'memory_rounded':
        return Icons.memory_rounded;
      case 'visibility_rounded':
        return Icons.visibility_rounded;
      default:
        return Icons.touch_app_rounded;
    }
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: cs.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
