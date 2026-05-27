import 'package:flutter/material.dart';

import '../theme.dart';

class MeowAgentIcon extends StatelessWidget {
  const MeowAgentIcon({super.key, this.size = 30, this.iconSize, this.radius});

  final double size;
  final double? iconSize;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cs.primary,
        borderRadius: BorderRadius.circular(radius ?? size * 0.36),
      ),
      child: Icon(
        Icons.smart_toy_rounded,
        size: iconSize ?? size * 0.56,
        color: Colors.white,
      ),
    );
  }
}
