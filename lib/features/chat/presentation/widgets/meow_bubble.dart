import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../../../app/theme.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../../../services/agent_runtime/runtime_models.dart';
import '../../data/chat_history_service.dart';

/// Reusable chat bubble for Meow Agent.
///
/// Two layout paths to avoid the Flutter `RenderDivider computeDryBaseline`
/// crash that triggers when GptMarkdown (which contains Dividers) is placed
/// under intrinsic-width measurement:
///
/// - **Plain layout** — IntrinsicWidth shrink + inline timestamp (WhatsApp).
///   Used for user messages and short assistant replies that have no markdown
///   syntax. Bubble sizes to content.
///
/// - **Markdown layout** — fixed max width, timestamp on its own row below.
///   Used for assistant messages containing markdown (lists, code, headings,
///   bold, links, etc.). Does NOT measure intrinsic width, so Divider-bearing
///   widgets are safe.
class MeowBubble extends StatelessWidget {
  const MeowBubble({
    super.key,
    required this.msg,
    this.isId = false,
    this.onConfirmAction,
    this.onActionTap,
    this.onLongPress,
  });

  final ChatMessage msg;
  final bool isId;
  final void Function(String action)? onConfirmAction;
  final void Function(ResultAction action, ChatMessage sourceMessage)?
  onActionTap;
  final VoidCallback? onLongPress;

  static final _quoteRegExp = RegExp(
    r'\[\[REPLY_QUOTE:([^\]]+)\]\](.*?)\[\[/REPLY_QUOTE\]\]\n?',
    dotAll: true,
  );


  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final isUser = msg.role == 'user';
    final isConfirmation = msg.content.contains('[[CONFIRMATION_REQUIRED]]');

    String? quoteRole;
    String? quoteText;
    var rawContent = msg.content;
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

    final useMarkdown = !isUser;
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
      child: useMarkdown
          ? _MarkdownLayout(
              content: displayContent,
              quoteRole: quoteRole,
              quoteText: quoteText,
              isConfirmation: isConfirmation,
              isId: isId,
              msg: msg,
              onConfirmAction: onConfirmAction,
              onActionTap: onActionTap,
              onLongPress: onLongPress,
            )
          : _PlainLayout(
              content: displayContent,
              quoteRole: quoteRole,
              quoteText: quoteText,
              isUser: isUser,
              isConfirmation: isConfirmation,
              isId: isId,
              msg: msg,
              onConfirmAction: onConfirmAction,
              onActionTap: onActionTap,
            ),
    );

    final sized = useMarkdown
        ? ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: container,
          )
        : ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: isUser ? 72 : 0,
              maxWidth: maxWidth,
            ),
            child: IntrinsicWidth(child: container),
          );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: onLongPress != null
          ? GestureDetector(onLongPress: onLongPress, child: sized)
          : sized,
    );
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
    required this.isId,
    required this.msg,
    required this.onConfirmAction,
    required this.onActionTap,
  });

  final String content;
  final String? quoteRole;
  final String? quoteText;
  final bool isUser;
  final bool isConfirmation;
  final bool isId;
  final ChatMessage msg;
  final void Function(String action)? onConfirmAction;
  final void Function(ResultAction action, ChatMessage sourceMessage)?
  onActionTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final s = AppStrings(isId ? 'id' : 'en');
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
        Text(content, style: textStyle),
        const SizedBox(height: 3),
        Align(
          alignment: Alignment.bottomRight,
          child: Text(
            formatBubbleTime(context, msg.timestamp),
            style: timeStyle,
          ),
        ),
        if (isConfirmation && onConfirmAction != null) ...[
          const SizedBox(height: 12),
          _ConfirmRow(s: s, onAction: onConfirmAction!),
        ],
        if (!isUser && msg.actions.isNotEmpty && onActionTap != null) ...[
          const SizedBox(height: 10),
          _ActionRow(actions: msg.actions, msg: msg, onTap: onActionTap!),
        ],
      ],
    );
  }
}

class _MarkdownLayout extends StatefulWidget {
  const _MarkdownLayout({
    required this.content,
    required this.quoteRole,
    required this.quoteText,
    required this.isConfirmation,
    required this.isId,
    required this.msg,
    required this.onConfirmAction,
    required this.onActionTap,
    this.onLongPress,
  });

  final String content;
  final String? quoteRole;
  final String? quoteText;
  final bool isConfirmation;
  final bool isId;
  final ChatMessage msg;
  final void Function(String action)? onConfirmAction;
  final void Function(ResultAction action, ChatMessage sourceMessage)?
  onActionTap;
  final VoidCallback? onLongPress;

  @override
  State<_MarkdownLayout> createState() => _MarkdownLayoutState();
}

class _MarkdownLayoutState extends State<_MarkdownLayout> {
  /// Max visible height for markdown content before clipping.
  static const double _maxVisibleHeight = 400;

  /// Content is considered "long" if it exceeds this char count or line count.
  static const int _maxChars = 600;
  static const int _maxLines = 20;

  bool get _isLong {
    return widget.content.length > _maxChars ||
        '\n'.allMatches(widget.content).length > _maxLines;
  }

  void _showFullContent() {
    final cs = Theme.of(context).colorScheme;
    final extras = context.extras;
    final s = AppStrings(widget.isId ? 'id' : 'en');
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
            // Action row: Copy + Reply.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _SheetAction(
                    icon: Icons.copy_rounded,
                    label: s.copyTooltip,
                    onTap: () {
                      Clipboard.setData(
                        ClipboardData(text: widget.content),
                      );
                      Navigator.of(ctx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(s.copied),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 12),
                  _SheetAction(
                    icon: Icons.reply_rounded,
                    label: widget.isId ? 'Balas' : 'Reply',
                    onTap: () {
                      Navigator.of(ctx).pop();
                      widget.onLongPress?.call();
                    },
                  ),
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
                child: GptMarkdown(
                  widget.content,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    height: 1.5,
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

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final s = AppStrings(widget.isId ? 'id' : 'en');
    final textStyle = TextStyle(
      color: cs.onSurface,
      fontSize: 14,
      height: 1.4,
    );

    final markdownWidget = GptMarkdown(widget.content, style: textStyle);
    final isLong = _isLong;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.quoteText != null && widget.quoteText!.isNotEmpty) ...[
          _QuoteChip(
            role: widget.quoteRole ?? '',
            text: widget.quoteText!,
            isUser: false,
          ),
        ],
        if (isLong) ...[
          ClipRect(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _maxVisibleHeight),
              child: markdownWidget,
            ),
          ),
          // Fade gradient overlay hint.
          Container(
            height: 32,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  (context.extras.card).withValues(alpha: 0),
                  context.extras.card,
                ],
              ),
            ),
          ),
          // "See more" button.
          GestureDetector(
            onTap: _showFullContent,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Text(
                widget.isId ? 'Lihat selengkapnya' : 'See more',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                ),
              ),
            ),
          ),
        ] else ...[
          markdownWidget,
        ],
        if (widget.isConfirmation && widget.onConfirmAction != null) ...[
          const SizedBox(height: 12),
          _ConfirmRow(s: s, onAction: widget.onConfirmAction!),
        ],
        if (widget.msg.actions.isNotEmpty && widget.onActionTap != null) ...[
          const SizedBox(height: 10),
          _ActionRow(
            actions: widget.msg.actions,
            msg: widget.msg,
            onTap: widget.onActionTap!,
          ),
        ],
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            formatBubbleTime(context, widget.msg.timestamp),
            style: TextStyle(
              fontSize: 10,
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
    );
  }
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
                    Icon(
                      _iconFor(a.icon),
                      size: 16,
                      color: cs.primary,
                    ),
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
      case 'dns_outlined':
        return Icons.dns_outlined;
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
