import 'package:flutter/material.dart';

/// Shimmer placeholder mimicking chat bubbles during initial load.
/// Staggered left/right alignment with varying widths for a natural look.
class ChatShimmer extends StatefulWidget {
  const ChatShimmer({super.key});

  @override
  State<ChatShimmer> createState() => _ChatShimmerState();
}

class _ChatShimmerState extends State<ChatShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final w = MediaQuery.of(context).size.width * 0.78;
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        final alpha = _animation.value;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          children: [
            const SizedBox(height: 120),
            _ShimmerBubble(
              width: w * 0.7,
              alignRight: false,
              alpha: alpha * 0.9,
              cs: cs,
            ),
            const SizedBox(height: 8),
            _ShimmerBubble(
              width: w * 0.5,
              alignRight: true,
              alpha: alpha * 0.6,
              cs: cs,
            ),
            const SizedBox(height: 8),
            _ShimmerBubble(
              width: w * 0.75,
              alignRight: false,
              alpha: alpha * 0.8,
              cs: cs,
            ),
            const SizedBox(height: 8),
            _ShimmerBubble(
              width: w * 0.45,
              alignRight: true,
              alpha: alpha * 0.5,
              cs: cs,
            ),
            const SizedBox(height: 8),
            _ShimmerBubble(
              width: w * 0.6,
              alignRight: false,
              alpha: alpha * 0.7,
              cs: cs,
            ),
          ],
        );
      },
    );
  }
}

class _ShimmerBubble extends StatelessWidget {
  const _ShimmerBubble({
    required this.width,
    required this.alignRight,
    required this.alpha,
    required this.cs,
  });

  final double width;
  final bool alignRight;
  final double alpha;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        width: width,
        height: alignRight ? 38 : 52,
        decoration: BoxDecoration(
          color: cs.onSurfaceVariant.withValues(alpha: 0.08 * alpha),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(alignRight ? 16 : 4),
            bottomRight: Radius.circular(alignRight ? 4 : 16),
          ),
        ),
      ),
    );
  }
}
