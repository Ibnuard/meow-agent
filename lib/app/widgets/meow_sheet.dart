import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Shared modal bottom-sheet shell used by picker-style sheets.
///
/// Keeps handle, radius, margins, keyboard inset, and bottom padding consistent
/// across language/sound pickers and custom action sheets.
class MeowSheet extends StatelessWidget {
  const MeowSheet({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.onClose,
    this.maxHeightFactor = 0.72,
    this.contentPadding = const EdgeInsets.fromLTRB(18, 0, 18, 0),
    this.footer,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final VoidCallback? onClose;
  final double maxHeightFactor;
  final EdgeInsets contentPadding;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final media = MediaQuery.of(context);
    final keyboardInset = media.viewInsets.bottom;
    final bottomPadding = keyboardInset > 0
        ? 12.0
        : media.viewPadding.bottom + 12;
    final sheetMargin = EdgeInsets.only(
      left: 10,
      right: 10,
      bottom: keyboardInset > 0 ? 8 : 0,
    );
    final sheetRadius = BorderRadius.vertical(
      top: const Radius.circular(24),
      bottom: keyboardInset > 0 ? const Radius.circular(24) : Radius.zero,
    );
    final availableHeight = math.max(
      180.0,
      media.size.height - media.padding.top - keyboardInset - 8,
    );
    final maxSheetHeight = math.min(
      media.size.height * maxHeightFactor,
      availableHeight,
    );

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          margin: sheetMargin,
          width: double.infinity,
          constraints: BoxConstraints(maxHeight: maxSheetHeight),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: sheetRadius,
            border: Border(top: BorderSide(color: extras.inputBorder)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 30,
                spreadRadius: -14,
                offset: const Offset(0, -10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: sheetRadius,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomPadding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.24),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: cs.onSurface,
                                ),
                              ),
                              if (subtitle != null) ...[
                                const SizedBox(height: 5),
                                Text(
                                  subtitle!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.35,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: onClose ?? () => Navigator.pop(context),
                          icon: Icon(
                            Icons.close_rounded,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: contentPadding,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: children,
                      ),
                    ),
                  ),
                  if (footer != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                      child: footer,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
