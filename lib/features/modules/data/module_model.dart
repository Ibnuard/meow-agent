/// Represents an installable module in Meow Agent.
class ModuleModel {
  const ModuleModel({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    this.enabled = false,
    this.settings = const {},
  });

  final String id;
  final String name;
  final String description;
  final String icon; // Material icon name or emoji.
  final bool enabled;
  final Map<String, bool> settings; // Toggle-based settings.

  ModuleModel copyWith({
    String? id,
    String? name,
    String? description,
    String? icon,
    bool? enabled,
    Map<String, bool>? settings,
  }) {
    return ModuleModel(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      icon: icon ?? this.icon,
      enabled: enabled ?? this.enabled,
      settings: settings ?? this.settings,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'icon': icon,
        'enabled': enabled,
        'settings': settings.map((k, v) => MapEntry(k, v)),
      };

  factory ModuleModel.fromJson(Map<String, dynamic> json) => ModuleModel(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String,
        icon: json['icon'] as String,
        enabled: json['enabled'] as bool? ?? false,
        settings: (json['settings'] as Map<String, dynamic>?)
                ?.map((k, v) => MapEntry(k, v as bool)) ??
            {},
      );
}

/// Registry of all available modules that can be installed.
class ModuleRegistry {
  static const clipboardAi = ModuleModel(
    id: 'clipboard_ai',
    name: 'Clipboard AI',
    description:
        'Process copied text with AI. Translate, summarize, rewrite, '
        'or explain any text from any app.',
    icon: '📋',
    settings: {
      'share_intent': true,
      'persistent_notification': false,
      'floating_bubble': false,
    },
  );

  static const appControl = ModuleModel(
    id: 'app_control',
    name: 'App Control',
    description:
        'Let AI open apps, URLs, and system settings on your behalf.',
    icon: '📱',
    settings: {
      'require_confirmation': true,
      'allow_system_settings': false,
      'allow_url_intents': true,
      'show_execution_toast': true,
    },
  );

  static const deviceContext = ModuleModel(
    id: 'device_context',
    name: 'Device Context',
    description:
        'Let agents read battery, network, storage, time, and locale.',
    icon: '📊',
    settings: {
      'allow_battery': true,
      'allow_network': true,
      'allow_storage': true,
      'allow_time_locale': true,
      'allow_foreground_app': false,
      'show_logs': true,
    },
  );

  static const List<ModuleModel> available = [
    clipboardAi,
    appControl,
    deviceContext,
  ];
}
