import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Animated mascot widget that brings the static meow.png to life.
///
/// Applies two animations to the single PNG asset:
/// 1. **Breathe** — subtle scale pulse (4s cycle, 1.0→1.04)
/// 2. **Jump** — on tap, a playful cat-like jump (squash → launch → land → settle)
///
/// Usage:
/// ```dart
/// const MeowMascot(size: 62)
/// ```
class MeowMascot extends StatefulWidget {
  const MeowMascot({
    super.key,
    this.size = 62,
    this.borderRadius = 20,
    this.showShadow = true,
    this.assetPath = 'assets/images/meow.png',
  });

  /// Logical size of the mascot image (width = height).
  final double size;

  /// Corner radius for the image clip.
  final double borderRadius;

  /// Whether to render the ground shadow below the mascot.
  /// Set to `false` when the mascot is inside a clipped container (circle, etc).
  final bool showShadow;

  /// Asset path override (for alternative mascot images).
  final String assetPath;

  @override
  State<MeowMascot> createState() => _MeowMascotState();
}

class _MeowMascotState extends State<MeowMascot>
    with TickerProviderStateMixin {
  late final AnimationController _breatheCtrl;
  late final AnimationController _jumpCtrl;

  // Jump phases: squash → launch → airborne → land → settle
  // Curve values handcrafted for a cat-like bounce.
  static const _jumpDuration = Duration(milliseconds: 600);

  @override
  void initState() {
    super.initState();

    // Breathe: 4 seconds full cycle (normal → expanded → normal).
    _breatheCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat();

    // Jump: triggered on tap, runs once.
    _jumpCtrl = AnimationController(
      vsync: this,
      duration: _jumpDuration,
    );
  }

  @override
  void dispose() {
    _breatheCtrl.dispose();
    _jumpCtrl.dispose();
    super.dispose();
  }

  void _onTap() {
    if (_jumpCtrl.isAnimating) return;
    _jumpCtrl.forward(from: 0.0);
  }

  /// Cat jump vertical offset curve:
  ///   0.00–0.15  squash down (crouch)       → +3px
  ///   0.15–0.45  launch up                  → -18px (peak)
  ///   0.45–0.70  fall down                  → +2px (land overshoot)
  ///   0.70–0.85  small bounce               → -4px
  ///   0.85–1.00  settle                     → 0px
  double _jumpY(double t) {
    if (t <= 0.15) {
      // Squash: ease down.
      final p = t / 0.15;
      return 3.0 * Curves.easeOut.transform(p);
    } else if (t <= 0.45) {
      // Launch: from +3 to -18.
      final p = (t - 0.15) / 0.30;
      return 3.0 - 21.0 * Curves.easeOut.transform(p);
    } else if (t <= 0.70) {
      // Fall: from -18 to +2.
      final p = (t - 0.45) / 0.25;
      return -18.0 + 20.0 * Curves.easeIn.transform(p);
    } else if (t <= 0.85) {
      // Small bounce: from +2 to -4.
      final p = (t - 0.70) / 0.15;
      return 2.0 - 6.0 * Curves.easeOut.transform(p);
    } else {
      // Settle: from -4 to 0.
      final p = (t - 0.85) / 0.15;
      return -4.0 + 4.0 * Curves.easeInOut.transform(p);
    }
  }

  /// Cat jump squash/stretch scale:
  ///   Squash phase:  scaleX widens, scaleY shortens (crouching)
  ///   Airborne:      scaleX narrows, scaleY stretches (elongated)
  ///   Land:          brief squash again
  ///   Settle:        back to 1.0
  ({double sx, double sy}) _jumpScale(double t) {
    if (t <= 0.15) {
      // Squash: wider + shorter.
      final p = Curves.easeOut.transform(t / 0.15);
      return (sx: 1.0 + 0.08 * p, sy: 1.0 - 0.08 * p);
    } else if (t <= 0.25) {
      // Transition to stretch.
      final p = Curves.easeIn.transform((t - 0.15) / 0.10);
      return (sx: 1.08 - 0.14 * p, sy: 0.92 + 0.14 * p);
    } else if (t <= 0.45) {
      // Airborne: narrower + taller.
      final p = (t - 0.25) / 0.20;
      return (sx: 0.94 + 0.06 * p, sy: 1.06 - 0.06 * p);
    } else if (t <= 0.60) {
      // Pre-land stretch.
      final p = Curves.easeIn.transform((t - 0.45) / 0.15);
      return (sx: 1.0 + 0.06 * p, sy: 1.0 - 0.06 * p);
    } else if (t <= 0.75) {
      // Land squash.
      final p = Curves.easeOut.transform((t - 0.60) / 0.15);
      return (sx: 1.06 - 0.06 * p, sy: 0.94 + 0.06 * p);
    } else {
      // Settle.
      return (sx: 1.0, sy: 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: Listenable.merge([_breatheCtrl, _jumpCtrl]),
        builder: (context, child) {
          final isJumping = _jumpCtrl.isAnimating;
          final jumpT = _jumpCtrl.value;

          // Breathe: gentle scale 1.0 → 1.04 → 1.0 (paused during jump).
          final breatheScale = isJumping
              ? 1.0
              : 1.0 + math.sin(_breatheCtrl.value * 2 * math.pi) * 0.04;

          // Jump transforms.
          final jumpY = isJumping ? _jumpY(jumpT) : 0.0;
          final jumpScaleXY = isJumping
              ? _jumpScale(jumpT)
              : (sx: 1.0, sy: 1.0);

          final totalSx = breatheScale * jumpScaleXY.sx;
          final totalSy = breatheScale * jumpScaleXY.sy;

          // Shadow: shrinks when mascot is in the air (jumpY < 0).
          final shadowWidth = widget.size * 0.55;
          final airFactor = jumpY < 0
              ? (1.0 + jumpY / 30.0).clamp(0.3, 1.0)
              : 1.0;
          final shadowOpacity = isJumping
              ? (0.12 * airFactor).clamp(0.03, 0.14)
              : 0.10;

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.translate(
                offset: Offset(0, jumpY),
                child: Transform(
                  alignment: Alignment.bottomCenter,
                  transform: Matrix4.diagonal3Values(totalSx, totalSy, 1.0),
                  child: child,
                ),
              ),
              if (widget.showShadow) ...[
                const SizedBox(height: 4),
                Container(
                  width: shadowWidth * airFactor,
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: shadowOpacity),
                        blurRadius: 8.0 * airFactor + 4,
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: Image.asset(
            widget.assetPath,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}
