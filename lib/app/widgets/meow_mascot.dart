import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Animated mascot widget that brings the static meow.png to life.
///
/// Idle: gentle breathing scale pulse.
/// On tap: randomly plays one of six cat-like animations.
class MeowMascot extends StatefulWidget {
  const MeowMascot({
    super.key,
    this.size = 62,
    this.borderRadius = 20,
    this.showShadow = true,
    this.assetPath = 'assets/images/meow.png',
  });

  final double size;
  final double borderRadius;
  final bool showShadow;
  final String assetPath;

  @override
  State<MeowMascot> createState() => _MeowMascotState();
}

enum _Action { none, jump, tilt, nod, wiggle, purr, stretch }

class _MeowMascotState extends State<MeowMascot>
    with TickerProviderStateMixin {
  late final AnimationController _breathe;
  late final AnimationController _act;
  _Action _cur = _Action.none;
  final _rng = math.Random();

  static const _pool = [
    _Action.jump,
    _Action.tilt,
    _Action.nod,
    _Action.wiggle,
    _Action.purr,
    _Action.stretch,
  ];

  int _durationMs(_Action a) => switch (a) {
    _Action.jump => 600,
    _Action.tilt => 900,
    _Action.nod => 1400,
    _Action.wiggle => 800,
    _Action.purr => 1000,
    _Action.stretch => 1100,
    _Action.none => 0,
  };

  @override
  void initState() {
    super.initState();
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat();
    _act = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _breathe.dispose();
    _act.dispose();
    super.dispose();
  }

  void _onTap() {
    if (_act.isAnimating) return;
    final a = _pool[_rng.nextInt(_pool.length)];
    setState(() => _cur = a);
    _act.duration = Duration(milliseconds: _durationMs(a));
    _act.forward(from: 0.0).then((_) {
      if (mounted) setState(() => _cur = _Action.none);
    });
  }

  // ── Per-action transform methods ──────────────────────────────────────────
  // Each returns (dx, dy, sx, sy, rot).

  static const _id = (dx: 0.0, dy: 0.0, sx: 1.0, sy: 1.0, rot: 0.0);

  ({double dx, double dy, double sx, double sy, double rot}) _xform(double t) =>
      switch (_cur) {
    _Action.jump => _jump(t),
    _Action.tilt => _tilt(t),
    _Action.nod => _nod(t),
    _Action.wiggle => _wiggle(t),
    _Action.purr => _purr(t),
    _Action.stretch => _stretch(t),
    _Action.none => _id,
  };

  // ── Jump: squash → launch → fall → bounce → settle ────────────────────────

  ({double dx, double dy, double sx, double sy, double rot}) _jump(double t) {
    double dy, sx, sy;
    if (t <= 0.15) {
      final p = Curves.easeOut.transform(t / 0.15);
      dy = 3 * p; sx = 1 + .08 * p; sy = 1 - .08 * p;
    } else if (t <= 0.45) {
      final p = Curves.easeOut.transform((t - .15) / .30);
      dy = 3 - 21 * p; sx = 1.08 - .14 * p; sy = .92 + .14 * p;
    } else if (t <= 0.70) {
      final p = Curves.easeIn.transform((t - .45) / .25);
      dy = -18 + 20 * p;
      final q = p < .6 ? p / .6 : 1.0;
      sx = .94 + .12 * q; sy = 1.06 - .12 * q;
    } else if (t <= 0.85) {
      final p = Curves.easeOut.transform((t - .70) / .15);
      dy = 2 - 6 * p; sx = 1.06 - .06 * p; sy = .94 + .06 * p;
    } else {
      final p = Curves.easeInOut.transform((t - .85) / .15);
      dy = -4 + 4 * p; sx = 1; sy = 1;
    }
    return (dx: 0, dy: dy, sx: sx, sy: sy, rot: 0);
  }

  // ── Curious tilt: lean right → lean left → settle ─────────────────────────

  ({double dx, double dy, double sx, double sy, double rot}) _tilt(double t) {
    double rot;
    if (t <= .30) {
      rot = .12 * Curves.easeInOut.transform(t / .30);
    } else if (t <= .60) {
      rot = .12 - .24 * Curves.easeInOut.transform((t - .30) / .30);
    } else if (t <= .85) {
      rot = -.12 + .12 * Curves.easeInOut.transform((t - .60) / .25);
    } else {
      rot = 0;
    }
    return (dx: 0, dy: 0, sx: 1, sy: 1, rot: rot);
  }

  // ── Sleepy nod: two forward nods, second deeper ───────────────────────────

  ({double dx, double dy, double sx, double sy, double rot}) _nod(double t) {
    double rot;
    if (t <= .30) {
      rot = .15 * Curves.easeIn.transform(t / .30);
    } else if (t <= .40) {
      rot = .15 * (1 - Curves.easeOut.transform((t - .30) / .10));
    } else if (t <= .45) {
      rot = 0;
    } else if (t <= .70) {
      rot = .22 * Curves.easeIn.transform((t - .45) / .25);
    } else if (t <= .82) {
      rot = .22 * (1 - Curves.easeOut.transform((t - .70) / .12));
    } else {
      rot = 0;
    }
    final dy = rot > 0 ? rot * 8 : 0.0;
    return (dx: 0, dy: dy, sx: 1, sy: 1, rot: rot);
  }

  // ── Pounce wiggle: lateral oscillation with slight crouch ─────────────────

  ({double dx, double dy, double sx, double sy, double rot}) _wiggle(double t) {
    if (t <= .75) {
      final freq = 3 + t * 10;
      final amp = 3.5 * (1 - t * .4);
      final dx = math.sin(t * freq * math.pi * 2) * amp;
      return (dx: dx, dy: 1.5, sx: 1 + .02 * (1 - t), sy: 1 - .03 * (1 - t), rot: 0);
    }
    final p = Curves.easeOut.transform((t - .75) / .25);
    return (dx: 0, dy: 1.5 * (1 - p), sx: 1, sy: 1, rot: 0);
  }

  // ── Purr vibrate: rapid micro-tremor with fade envelope ───────────────────

  ({double dx, double dy, double sx, double sy, double rot}) _purr(double t) {
    final env = t < .1 ? t / .1 : t > .85 ? (1 - t) / .15 : 1.0;
    final a = 1.3 * env;
    final dx = math.sin(t * 28 * math.pi) * a;
    final dy = math.cos(t * 22 * math.pi) * a * .5;
    return (dx: dx, dy: dy, sx: 1, sy: 1, rot: 0);
  }

  // ── Lazy stretch: widen → stretch tall → settle ───────────────────────────

  ({double dx, double dy, double sx, double sy, double rot}) _stretch(double t) {
    double sx, sy, dy;
    if (t <= .30) {
      final p = Curves.easeInOut.transform(t / .30);
      sx = 1 + .10 * p; sy = 1 - .05 * p; dy = 2 * p;
    } else if (t <= .55) {
      final p = Curves.easeInOut.transform((t - .30) / .25);
      sx = 1.10 - .14 * p; sy = .95 + .13 * p; dy = 2 - 4 * p;
    } else if (t <= .80) {
      final p = Curves.easeInOut.transform((t - .55) / .25);
      sx = .96 + .04 * p; sy = 1.08 - .08 * p; dy = -2 + 2 * p;
    } else {
      sx = 1; sy = 1; dy = 0;
    }
    return (dx: 0, dy: dy, sx: sx, sy: sy, rot: 0);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: Listenable.merge([_breathe, _act]),
        builder: (context, child) {
          final acting = _act.isAnimating;
          final f = acting ? _xform(_act.value) : _id;

          // Breathing pauses during action to avoid visual conflict.
          final bScale = acting
              ? 1.0
              : 1 + math.sin(_breathe.value * 2 * math.pi) * .04;

          final sx = bScale * f.sx;
          final sy = bScale * f.sy;

          // Shadow reacts to vertical offset.
          final airFactor = f.dy < 0 ? (1 + f.dy / 30).clamp(0.3, 1.0) : 1.0;
          final shadowOp = acting
              ? (0.12 * airFactor).clamp(0.03, 0.14)
              : 0.10;

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.translate(
                offset: Offset(f.dx, f.dy),
                child: Transform.rotate(
                  angle: f.rot,
                  alignment: Alignment.center,
                  child: Transform.scale(
                    scaleX: sx,
                    scaleY: sy,
                    alignment: Alignment.center,
                    child: child,
                  ),
                ),
              ),
              if (widget.showShadow) ...[
                const SizedBox(height: 4),
                Container(
                  width: widget.size * .55 * airFactor,
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: shadowOp),
                        blurRadius: 8 * airFactor + 4,
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
