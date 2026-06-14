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
    settings:
        (json['settings'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(k, v as bool),
        ) ??
        {},
  );
}

/// Registry of all available modules that can be installed.
class ModuleRegistry {
  static const deviceContext = ModuleModel(
    id: 'device_context',
    name: 'Device Context',
    description:
        'Let agents read device state, app context, connectivity, clipboard, '
        'and launch apps, URLs, or system settings.',
    icon: '📊',
    settings: {
      'allow_battery': true,
      'allow_network': true,
      'allow_storage': true,
      'allow_time_locale': true,
      'allow_foreground_app': false,
      'allow_charging': true,
      'allow_dnd': true,
      'allow_bluetooth': true,
      'allow_clipboard_read': false,
      'allow_clipboard_write': false,
      'allow_open_apps': false,
      'allow_background_launch': false,
    },
  );

  static const notificationIntelligence = ModuleModel(
    id: 'notification_intelligence',
    name: 'Notification',
    description:
        'Manage agent notifications, read Android notifications, and keep a clipboard quick action ready.',
    icon: '🔔',
    settings: {
      'allow_read': false,
      'allow_reply': false,
      'persistent_notification': false,
    },
  );

  static const notes = ModuleModel(
    id: 'notes',
    name: 'Notes',
    description:
        'Create and manage markdown notes for you and your agents. '
        'Local-first persistent memory layer.',
    icon: '📝',
    settings: {
      'allow_create': true,
      'allow_read': true,
      'allow_search': true,
    },
  );

  static const files = ModuleModel(
    id: 'files',
    name: 'Files',
    description:
        'Create, read, edit, delete, and organize files within the agent workspace. '
        'Sandboxed to the workspace directory only.',
    icon: '📁',
    settings: {
      'allow_create': true,
      'allow_read': true,
      'allow_write': true,
      'allow_delete': true,
      'allow_organize': true,
    },
  );

  static const calendar = ModuleModel(
    id: 'calendar',
    name: 'Calendar',
    description:
        'Local calendar for scheduling events and reminders. '
        'Agent can create and manage your schedule.',
    icon: '📅',
    settings: {
      'allow_create': true,
      'allow_read': true,
      'allow_update': true,
      'allow_delete': true,
    },
  );

  static const workflows = ModuleModel(
    id: 'workflows',
    name: 'Workflow Manager',
    description:
        'Jadwalkan tugas otomatis agent dengan notifikasi. '
        'Buat workflow yang menjalankan prompt di waktu tertentu atau berkala.',
    icon: '⚡',
    settings: {
      'allow_create': true,
      'allow_read': true,
      'allow_update': true,
      'allow_delete': true,
    },
  );

  static const web = ModuleModel(
    id: 'web',
    name: 'API Store',
    description:
        'Fetch HTTP APIs and register reusable endpoints. '
        'Any agent can call stored APIs by name with auto-filled parameters.',
    icon: '🌐',
    settings: {
      'allow_fetch': true,
      'allow_register': true,
      'allow_call': true,
      'allow_remove': true,
    },
  );

  static const vm = ModuleModel(
    id: 'vm',
    name: 'VM Runtime',
    description:
        'A local Linux runtime for running shell commands. '
        'You install and start the runtime — agents only run commands inside it.',
    icon: 'terminal',
    settings: {
      // Only one agent-facing permission: run shell commands inside the
      // already-running runtime. Install/start/stop are user-only actions
      // performed from the VM Runtime screen.
      'allow_run_command': true,
    },
  );

  static const communication = ModuleModel(
    id: 'communication',
    name: 'Communication',
    description:
        'Automate calls, SMS, and contact resolution. '
        'Make phone calls, send SMS, and resolve contacts hands-free.',
    icon: '📲',
    settings: {
      'call_enabled': false,
      'sms_enabled': false,
      'contact_access': false,
    },
  );

  static const superPower = ModuleModel(
    id: 'super_power',
    name: 'Super Power',
    description:
        'Advanced overlay and device automation. '
        'Enable floating bubble and Shizuku-powered app agentic control.',
    icon: '⚡',
    settings: {
      'overlay_bubble': false,
      'app_agentic': false,
      'run_locked_device': false,
    },
  );

  static const List<ModuleModel> available = [
    deviceContext,
    notificationIntelligence,
    notes,
    files,
    calendar,
    workflows,
    web,
    vm,
    communication,
    superPower,
  ];
}
