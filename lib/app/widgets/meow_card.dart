import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// A floating glass-surface card for grouping content.
///
/// Provides:
/// - Translucent dark fill (glassmorphism in dark mode).
/// - Subtle border highlight.
/// - Optional backdrop blur.
/// - Generous internal padding.
class MeowCard extends StatelessWidget {
  const MeowCard({
    super.key,
    this.padding = const EdgeInsets.all(20),
    this.blur = false,
    this.child,
  });

  final EdgeInsets padding;

  /// Whether to apply a backdrop blur. Use sparingly — only when the card
  /// overlays scrollable content.
  final bool blur;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final extras = context.extras;

    Widget surface = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: extras.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: extras.subtleBorder, width: 1),
      ),
      child: child,
    );

    if (blur) {
      surface = ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: surface,
        ),
      );
    }

    return surface;
  }
}
