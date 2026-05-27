import 'package:flutter/material.dart';

import '../../features/agents/data/agent_appearance.dart';
import '../../features/agents/data/agent_model.dart';

/// Renders an agent's avatar using its [AgentModel.iconKey] and
/// [AgentModel.colorKey] preferences.
///
/// Pass [agent] when available to honor the user's theme; otherwise the
/// widget falls back to the default robot/blue look. Use this widget
/// everywhere agents are displayed — dropdowns, chat header, list rows —
/// so the user's choice propagates consistently.
class MeowAgentIcon extends StatelessWidget {
  const MeowAgentIcon({
    super.key,
    this.agent,
    this.size = 30,
    this.iconSize,
    this.radius,
  });

  /// Pass the agent to render its custom icon + color. When null, falls
  /// back to the default appearance.
  final AgentModel? agent;
  final double size;
  final double? iconSize;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final iconData = resolveAgentIcon(agent?.iconKey);
    final tint = resolveAgentColor(agent?.colorKey);

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(radius ?? size * 0.36),
      ),
      child: Icon(
        iconData,
        size: iconSize ?? size * 0.56,
        color: Colors.white,
      ),
    );
  }
}
