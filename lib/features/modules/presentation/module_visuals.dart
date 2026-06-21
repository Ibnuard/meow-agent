import 'package:flutter/material.dart';

import '../../../app/theme.dart';

class ModuleVisuals {
  const ModuleVisuals._();

  static IconData iconFor(String id) {
    return switch (id) {
      'device_context' => Icons.monitor_heart_rounded,
      'notification_intelligence' => Icons.notifications_rounded,
      'notes' => Icons.edit_note_rounded,
      'files' => Icons.folder_rounded,
      'calendar' => Icons.calendar_month_rounded,
      'workflows' => Icons.bolt_rounded,
      'web' => Icons.cloud_rounded,
      'vm' => Icons.terminal_rounded,
      'communication' => Icons.send_rounded,
      'database' => Icons.storage_rounded,
      'miniapp' => Icons.widgets_outlined,
      'skills' => Icons.psychology_rounded,
      _ => Icons.extension_rounded,
    };
  }

  static Color accentFor(String id) {
    return switch (id) {
      'device_context' => const Color(0xFF14B8A6),
      'notification_intelligence' => const Color(0xFFF59E0B),
      'notes' => const Color(0xFFEC4899),
      'files' => const Color(0xFFEAB308),
      'calendar' => const Color(0xFFEF4444),
      'workflows' => const Color(0xFF3B82F6),
      'web' => const Color(0xFF06B6D4),
      'vm' => const Color(0xFF10B981),
      'communication' => const Color(0xFF22C55E),
      'database' => const Color(0xFF6366F1),
      'miniapp' => const Color(0xFFA855F7),
      'skills' => const Color(0xFFF43F5E),
      _ => const Color(0xFF64748B),
    };
  }
}

class ModuleIconBadge extends StatelessWidget {
  const ModuleIconBadge({
    super.key,
    required this.moduleId,
    this.size = 44,
    this.iconSize = 21,
    this.radius = 16,
  });

  final String moduleId;
  final double size;
  final double iconSize;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = ModuleVisuals.accentFor(moduleId);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: context.extras.subtleBorder),
      ),
      alignment: Alignment.center,
      child: Icon(
        ModuleVisuals.iconFor(moduleId),
        size: iconSize,
        color: accent,
      ),
    );
  }
}
