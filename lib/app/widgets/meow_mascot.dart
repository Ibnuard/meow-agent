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

class _MeowMascotState extends State<MeowMascot> with TickerProviderStateMixin {
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
    _Action.jump => 850,
    _Action.tilt => 1100,
    _Action.nod => 1600,
    _Action.wiggle => 1000,
    _Action.purr => 1600,
    _Action.stretch => 1300,
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

  // ── Jump: anticipation squash → launch (easeOut) → hang → fall (easeIn)
  //   → elastic landing squash → settle ─────────────────────────────────────

  ({double dx, double dy, double sx, double sy, double rot}) _jump(double t) {
    double dy, sx, sy;
    if (t <= 0.10) {
      // Anticipation — crouch before launch (adds weight feel)
      final p = Curves.easeInOut.transform(t / 0.10);
      dy = 8 * p;
      sx = 1 + .18 * p;
      sy = 1 - .14 * p;
    } else if (t <= 0.38) {
      // Launch — fast rise, decelerates (gravity deceleration)
      final p = Curves.easeOut.transform((t - 0.10) / 0.28);
      dy = 8 - 44 * p;
      sx = 1.18 - .22 * p;
      sy = .86 + .20 * p;
    } else if (t <= 0.58) {
      // Hang at peak — brief float, slight overshoot
      final p = ((t - 0.38) / 0.20).clamp(0.0, 1.0);
      dy = -36 + 4 * math.sin(p * math.pi);
      sx = .96 + .04 * math.sin(p * math.pi);
      sy = 1.06 - .06 * math.sin(p * math.pi);
    } else if (t <= 0.76) {
      // Fall — accelerating (easeIn mimics gravity acceleration)
      final p = Curves.easeIn.transform((t - 0.58) / 0.18);
      dy = -32 + 32 * p;
      sx = 1.0 + .02 * (1 - p);
      sy = 1.0 - .02 * (1 - p);
    } else if (t <= 0.86) {
      // Elastic landing — big squash on impact, springs back
      final p = Curves.elasticOut.transform((t - 0.76) / 0.10);
      dy = 10 * (1 - p);
      sx = 1 + .14 * (1 - p);
      sy = 1 - .12 * (1 - p);
    } else {
      // Settle — small secondary bounce
      final p = Curves.easeOut.transform((t - 0.86) / 0.14);
      dy = 10 * (1 - p);
      sx = 1.0;
      sy = 1.0;
    }
    return (dx: 0, dy: dy, sx: sx, sy: sy, rot: 0);
  }

  // ── Curious tilt: lean right (anticipation) → overshoot left → settle ──────
  // Added dx + sx/sy secondary motion for a cat-like head-bob feel.

  ({double dx, double dy, double sx, double sy, double rot}) _tilt(double t) {
    double rot, dx, sx;
    if (t <= .25) {
      // Lean right — squash anticipation first
      final p = Curves.easeInOut.transform(t / .25);
      rot = .10 * p;
      dx = 2.5 * p;
      sx = 1 + .04 * p;
    } else if (t <= .55) {
      // Lean left — overshoot past center
      final p = Curves.easeInOut.transform((t - .25) / .30);
      rot = .10 - .30 * p;
      dx = 2.5 - 5 * p;
      sx = 1.04 - .06 * p;
    } else if (t <= .75) {
      // Spring back right — overshoot
      final p = Curves.easeOut.transform((t - .55) / .20);
      rot = -.20 + .20 * p;
      dx = -2.5 + 2.5 * p;
      sx = .98 + .02 * p;
    } else {
      // Settle to center
      final p = Curves.easeInOut.transform((t - .75) / .25);
      rot = .0 * (1 - p);
      dx = 0 * (1 - p);
      sx = 1.0;
    }
    return (dx: dx, dy: 0, sx: sx, sy: 1, rot: rot);
  }

  // ── Sleepy nod: two nods with overshoot — second deeper ─────────────────────
  // Secondary: squash at peak, slight scale pulse on recovery.

  ({double dx, double dy, double sx, double sy, double rot}) _nod(double t) {
    double rot, sx, sy;
    if (t <= .22) {
      // First nod down
      final p = Curves.easeInOut.transform(t / .22);
      rot = .18 * p;
      sx = 1 - .04 * p;
      sy = 1 + .03 * p;
    } else if (t <= .32) {
      // Spring back up — slight overshoot
      final p = Curves.elasticOut.transform((t - .22) / .10);
      rot = .18 * (1 - p);
      sx = .96 + .04 * p;
      sy = 1.03 - .03 * p;
    } else if (t <= .36) {
      // Pause — head up, relaxed
      rot = 0;
      sx = 1;
      sy = 1;
    } else if (t <= .62) {
      // Second nod down — deeper, slower, more deliberate
      final p = Curves.easeInOut.transform((t - .36) / .26);
      rot = .28 * p;
      sx = 1 - .05 * p;
      sy = 1 + .04 * p;
    } else if (t <= .78) {
      // Spring back up — bigger overshoot on second recovery
      final p = Curves.elasticOut.transform((t - .62) / .16);
      rot = .28 * (1 - p);
      sx = .95 + .05 * p;
      sy = 1.04 - .04 * p;
    } else {
      // Settle to rest
      rot = 0;
      sx = 1.0;
      sy = 1.0;
    }
    final bobDy = rot > 0 ? rot * 10 : 0.0;
    return (dx: 0, dy: bobDy, sx: sx, sy: sy, rot: rot);
  }

  // ── Pounce wiggle: crouch → lateral oscillation → settle ────────────────────
  // Uses decaying sine with anticipation squat at start.

  ({double dx, double dy, double sx, double sy, double rot}) _wiggle(double t) {
    double dx, dy, sx, sy, rot;
    if (t <= .08) {
      // Anticipation squat before pounce
      final p = Curves.easeOut.transform(t / .08);
      dx = 0;
      dy = 3 * p;
      sx = 1 + .08 * p;
      sy = 1 - .06 * p;
      rot = 0;
    } else if (t <= .65) {
      // Pounce oscillation — 2.5 full cycles, decaying amplitude
      final p = ((t - 0.08) / 0.57).clamp(0.0, 1.0);
      final phase = p * 2.5 * math.pi * 2;
      final decay = 1 - p * 0.65;
      dx = math.sin(phase) * 8 * decay;
      // Lateral tilt during pounce (cat-body twist)
      rot = math.sin(phase) * 0.08 * decay;
      // Crouch at start of pounce, gradually extend
      dy = 3 * (1 - p) + (-1.5 * math.sin(p * math.pi * 2) * decay);
      sx = 1 + .02 * decay;
      sy = 1 - .04 * decay;
    } else if (t <= .82) {
      // Settle from crouch
      final p = Curves.easeOut.transform((t - 0.65) / 0.17);
      dx = 0 * (1 - p);
      dy = 1.5 * (1 - p);
      sx = 1 + .01 * (1 - p);
      sy = 1 - .01 * (1 - p);
      rot = 0;
    } else {
      // Final spring to rest
      final p = Curves.elasticOut.transform((t - 0.82) / 0.18);
      dx = 0;
      dy = 1.5 * (1 - p);
      sx = 1.0;
      sy = 1.0;
      rot = 0;
    }
    return (dx: dx, dy: dy, sx: sx, sy: sy, rot: rot);
  }

  // ── Purr vibrate: strong micro-tremor with breathing envelope ───────────────
  // Amplitude amplified 4×, frequency tuned for visible shake.

  ({double dx, double dy, double sx, double sy, double rot}) _purr(double t) {
    // Two-phase envelope: ramp up (0→15%), sustain, ramp down (85%→100%)
    final env = t < .15
        ? t / .15
        : t > .85
        ? (1 - t) / .15
        : 1.0;
    // Main tremor — higher amplitude (6px vs 1.3px)
    final a = 6.0 * env;
    // Slightly different frequencies per axis so it looks organic, not robotic
    final dx = math.sin(t * 18 * math.pi) * a;
    final dy = math.cos(t * 14 * math.pi) * a * 0.6;
    // Subtle scale pulse synced with tremor
    final sx = 1 + math.sin(t * 9 * math.pi) * 0.015 * env;
    final sy = 1 + math.cos(t * 9 * math.pi) * 0.015 * env;
    return (dx: dx, dy: dy, sx: sx, sy: sy, rot: 0);
  }

  // ── Lazy stretch: squat → elongate up → sway → settle ────────────────────────
  // Added anticipation squat, overshoot sway, and elastic settle.

  ({double dx, double dy, double sx, double sy, double rot}) _stretch(
    double t,
  ) {
    double sx, sy, dy, rot;
    if (t <= .10) {
      // Anticipation squat
      final p = Curves.easeInOut.transform(t / .10);
      sx = 1 + .10 * p;
      sy = 1 - .08 * p;
      dy = 4 * p;
      rot = 0;
    } else if (t <= .40) {
      // Rise and elongate — pushes up
      final p = Curves.easeOut.transform((t - .10) / .30);
      sx = 1.10 - .16 * p;
      sy = .92 + .18 * p;
      dy = 4 - 8 * p;
      rot = 0;
    } else if (t <= .55) {
      // Hold at peak — slight sway (like a cat stretching tall)
      final p = ((t - .40) / .15).clamp(0.0, 1.0);
      sx = .94;
      sy = 1.10;
      dy = -4 + 2 * math.sin(p * math.pi);
      rot = math.sin(p * math.pi) * 0.04;
    } else if (t <= .78) {
      // Controlled descent
      final p = Curves.easeInOut.transform((t - .55) / .23);
      sx = .94 + .10 * p;
      sy = 1.10 - .12 * p;
      dy = -4 + 6 * p;
      rot = 0.04 * (1 - p);
    } else {
      // Elastic settle — slight bounce overshoot
      final p = Curves.elasticOut.transform((t - .78) / .22);
      sx = 1.0;
      sy = 1.0;
      dy = 2 * (1 - p);
      rot = 0;
    }
    return (dx: 0, dy: dy, sx: sx, sy: sy, rot: rot);
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
          final shadowOp = acting ? (0.12 * airFactor).clamp(0.03, 0.14) : 0.10;

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
