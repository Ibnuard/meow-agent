import 'package:flutter/material.dart';

/// Curated, on-theme presets for agent appearance. The palette is
/// hand-picked to stay calm, harmonious, and consistent with the Meow
/// Agent visual identity (see AGENTS.md). Avoid adding raw colors here.
///
/// All keys are stable strings so they survive serialization. Resolvers
/// fall back gracefully when a key is missing or unknown (e.g. from older
/// agents created before the appearance system existed).

@immutable
class AgentIconOption {
  const AgentIconOption({
    required this.key,
    required this.icon,
    required this.labelId,
    required this.labelEn,
  });

  final String key;
  final IconData icon;
  final String labelId;
  final String labelEn;

  String label(bool isId) => isId ? labelId : labelEn;
}

@immutable
class AgentColorOption {
  const AgentColorOption({
    required this.key,
    required this.color,
    required this.labelId,
    required this.labelEn,
  });

  final String key;
  final Color color;
  final String labelId;
  final String labelEn;

  String label(bool isId) => isId ? labelId : labelEn;
}

/// Default keys when an agent doesn't yet have an appearance set.
const String kDefaultAgentIconKey = 'robot';
const String kDefaultAgentColorKey = 'blue';

/// Icon presets — minimal, modern, slightly rounded, consistent stroke.
/// Per AGENTS.md, do NOT mix filled/outline styles — every entry uses the
/// `_rounded` family for visual cohesion.
const List<AgentIconOption> kAgentIconOptions = [
  AgentIconOption(
    key: 'robot',
    icon: Icons.smart_toy_rounded,
    labelId: 'Robot',
    labelEn: 'Robot',
  ),
  AgentIconOption(
    key: 'spark',
    icon: Icons.auto_awesome_rounded,
    labelId: 'Spark',
    labelEn: 'Spark',
  ),
  AgentIconOption(
    key: 'brain',
    icon: Icons.psychology_rounded,
    labelId: 'Otak',
    labelEn: 'Brain',
  ),
  AgentIconOption(
    key: 'chat',
    icon: Icons.forum_rounded,
    labelId: 'Chat',
    labelEn: 'Chat',
  ),
  AgentIconOption(
    key: 'rocket',
    icon: Icons.rocket_launch_rounded,
    labelId: 'Roket',
    labelEn: 'Rocket',
  ),
  AgentIconOption(
    key: 'palette',
    icon: Icons.palette_rounded,
    labelId: 'Palet',
    labelEn: 'Palette',
  ),
  AgentIconOption(
    key: 'book',
    icon: Icons.menu_book_rounded,
    labelId: 'Buku',
    labelEn: 'Book',
  ),
  AgentIconOption(
    key: 'lab',
    icon: Icons.science_rounded,
    labelId: 'Lab',
    labelEn: 'Lab',
  ),
  AgentIconOption(
    key: 'moon',
    icon: Icons.nightlight_round,
    labelId: 'Bulan',
    labelEn: 'Moon',
  ),
  AgentIconOption(
    key: 'sun',
    icon: Icons.wb_sunny_rounded,
    labelId: 'Matahari',
    labelEn: 'Sun',
  ),
  AgentIconOption(
    key: 'headset',
    icon: Icons.headset_mic_rounded,
    labelId: 'Headset',
    labelEn: 'Headset',
  ),
  AgentIconOption(
    key: 'flame',
    icon: Icons.local_fire_department_rounded,
    labelId: 'Api',
    labelEn: 'Flame',
  ),
];

/// Color presets — Tailwind 500 family at similar luminance so every
/// agent stays on-brand. The first entry is the theme primary (blue).
const List<AgentColorOption> kAgentColorOptions = [
  AgentColorOption(
    key: 'blue',
    color: Color(0xFF3B82F6), // Theme primary.
    labelId: 'Biru',
    labelEn: 'Blue',
  ),
  AgentColorOption(
    key: 'violet',
    color: Color(0xFF8B5CF6),
    labelId: 'Ungu',
    labelEn: 'Violet',
  ),
  AgentColorOption(
    key: 'cyan',
    color: Color(0xFF06B6D4),
    labelId: 'Cyan',
    labelEn: 'Cyan',
  ),
  AgentColorOption(
    key: 'emerald',
    color: Color(0xFF10B981),
    labelId: 'Hijau',
    labelEn: 'Emerald',
  ),
  AgentColorOption(
    key: 'amber',
    color: Color(0xFFF59E0B),
    labelId: 'Amber',
    labelEn: 'Amber',
  ),
  AgentColorOption(
    key: 'rose',
    color: Color(0xFFF43F5E),
    labelId: 'Mawar',
    labelEn: 'Rose',
  ),
  AgentColorOption(
    key: 'pink',
    color: Color(0xFFEC4899),
    labelId: 'Pink',
    labelEn: 'Pink',
  ),
  AgentColorOption(
    key: 'slate',
    color: Color(0xFF64748B),
    labelId: 'Slate',
    labelEn: 'Slate',
  ),
];

/// Resolves [iconKey] to an [IconData], falling back to the default if
/// the key is null, empty, or unknown.
IconData resolveAgentIcon(String? iconKey) {
  if (iconKey == null || iconKey.isEmpty) {
    return _findIcon(kDefaultAgentIconKey).icon;
  }
  return _findIcon(iconKey).icon;
}

/// Resolves [colorKey] to a [Color], falling back to the default if
/// the key is null, empty, or unknown.
Color resolveAgentColor(String? colorKey) {
  if (colorKey == null || colorKey.isEmpty) {
    return _findColor(kDefaultAgentColorKey).color;
  }
  return _findColor(colorKey).color;
}

AgentIconOption _findIcon(String key) {
  return kAgentIconOptions.firstWhere(
    (o) => o.key == key,
    orElse: () => kAgentIconOptions.first,
  );
}

AgentColorOption _findColor(String key) {
  return kAgentColorOptions.firstWhere(
    (o) => o.key == key,
    orElse: () => kAgentColorOptions.first,
  );
}
