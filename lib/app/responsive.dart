import 'package:flutter/material.dart';

/// Responsive breakpoints and utilities for Meow Agent.
///
/// Phone-first design that gracefully adapts to tablets without
/// breaking the "calm AI companion" layout philosophy.
class Responsive {
  Responsive._();

  /// Width breakpoint: anything wider is treated as tablet.
  static const double tabletBreakpoint = 600;

  /// Max content width for tablet layouts — prevents content from
  /// stretching uncomfortably wide on large screens.
  static const double maxContentWidth = 520;

  /// Whether the current context is a tablet-sized screen.
  static bool isTablet(BuildContext context) =>
      MediaQuery.sizeOf(context).shortestSide >= tabletBreakpoint;

  /// Maximum text scale factor to prevent extreme accessibility
  /// settings from breaking fixed-size layouts (chat bubbles, dock, etc).
  static const double maxTextScale = 1.35;

  /// Clamps the text scale factor within safe bounds.
  static MediaQueryData clampTextScale(MediaQueryData data) {
    return data.copyWith(
      textScaler: data.textScaler.clamp(
        minScaleFactor: 0.8,
        maxScaleFactor: maxTextScale,
      ),
    );
  }

  /// Returns an appropriate horizontal padding for the screen width.
  /// Tablets get more padding to keep content centered.
  static EdgeInsets screenPadding(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 900) return const EdgeInsets.symmetric(horizontal: 80);
    if (width >= tabletBreakpoint) {
      return const EdgeInsets.symmetric(horizontal: 40);
    }
    return const EdgeInsets.symmetric(horizontal: 16);
  }
}
