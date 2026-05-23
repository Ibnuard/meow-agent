import 'package:flutter/material.dart';

import '../theme.dart';

/// A breathable section container with optional title and subtitle.
///
/// Provides the spacing hierarchy:
///   [title]  — medium emphasis, 15px semibold
///   [subtitle] — low emphasis, 13px muted
///   [gap]
///   [child]
///
/// Use this to group related form fields or settings.
class MeowSection extends StatelessWidget {
  const MeowSection({
    super.key,
    this.title,
    this.subtitle,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
    this.bottomSpacing = 28,
    required this.child,
  });

  final String? title;
  final String? subtitle;
  final EdgeInsets padding;
  final double bottomSpacing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
                letterSpacing: -0.2,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: cs.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 16),
          ],
          child,
          SizedBox(height: bottomSpacing),
        ],
      ),
    );
  }
}
