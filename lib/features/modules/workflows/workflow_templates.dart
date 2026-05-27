import 'workflow_model.dart';

/// Pre-built workflow templates for common use cases.
class WorkflowTemplate {
  const WorkflowTemplate({
    required this.id,
    required this.title,
    required this.titleId,
    required this.description,
    required this.descriptionId,
    required this.icon,
    required this.category,
    required this.defaultPrompt,
    this.defaultTrigger,
    this.defaultSteps = const [],
    this.defaultVariables = const {},
    this.defaultPriority = WorkflowPriority.normal,
    this.defaultTimeoutSeconds = 60,
  });

  final String id;
  final String title;
  final String titleId;
  final String description;
  final String descriptionId;
  final String icon;
  final TemplateCategory category;
  final String defaultPrompt;
  final TriggerConfig? defaultTrigger;
  final List<WorkflowStep> defaultSteps;
  final Map<String, String> defaultVariables;
  final WorkflowPriority defaultPriority;
  final int defaultTimeoutSeconds;
}

enum TemplateCategory {
  productivity,
  monitoring,
  communication,
  automation,
  health,
}

/// Registry of all available workflow templates.
class WorkflowTemplateRegistry {
  static const List<WorkflowTemplate> templates = [
    // ─── Productivity ─────────────────────────────────────────────────────────
    WorkflowTemplate(
      id: 'tpl_morning_briefing',
      title: 'Morning Briefing',
      titleId: 'Briefing Pagi',
      description: 'Get a daily summary of weather, calendar, and tasks every morning.',
      descriptionId: 'Dapatkan ringkasan cuaca, kalender, dan tugas setiap pagi.',
      icon: '🌅',
      category: TemplateCategory.productivity,
      defaultPrompt:
          'Berikan briefing pagi saya: ringkasan cuaca hari ini, jadwal kalender, '
          'dan tugas penting yang perlu diselesaikan. Buat ringkas dan actionable.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.schedule,
        hour: 7,
        minute: 0,
        daysOfWeek: [1, 2, 3, 4, 5],
      ),
      defaultPriority: WorkflowPriority.high,
    ),

    WorkflowTemplate(
      id: 'tpl_daily_journal',
      title: 'Daily Journal Prompt',
      titleId: 'Jurnal Harian',
      description: 'Get a reflective journaling prompt every evening.',
      descriptionId: 'Dapatkan prompt refleksi jurnal setiap malam.',
      icon: '📓',
      category: TemplateCategory.productivity,
      defaultPrompt:
          'Buat prompt refleksi jurnal harian yang thoughtful. '
          'Tanyakan tentang pencapaian hari ini, tantangan yang dihadapi, '
          'dan rencana untuk besok. Simpan sebagai note.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.schedule,
        hour: 21,
        minute: 0,
        daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
      ),
      defaultSteps: [
        WorkflowStep(
          id: 'generate_prompt',
          prompt: 'Buat prompt refleksi jurnal yang unik untuk hari ini.',
          timeoutSeconds: 30,
        ),
        WorkflowStep(
          id: 'save_note',
          prompt: 'Simpan prompt berikut sebagai note baru dengan judul "Jurnal {{date}}": {{prev}}',
          condition: "prev.isNotEmpty",
          timeoutSeconds: 15,
        ),
      ],
      defaultVariables: {'date': ''},
    ),

    // ─── Monitoring ───────────────────────────────────────────────────────────
    WorkflowTemplate(
      id: 'tpl_battery_saver',
      title: 'Battery Saver Alert',
      titleId: 'Peringatan Baterai',
      description: 'Get tips to save battery when it drops below threshold.',
      descriptionId: 'Dapatkan tips hemat baterai saat di bawah threshold.',
      icon: '🔋',
      category: TemplateCategory.monitoring,
      defaultPrompt:
          'Baterai saya rendah. Cek aplikasi apa yang sedang berjalan '
          'dan berikan saran untuk menghemat baterai.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.event,
        eventKind: EventTriggerKind.batteryLow,
        eventParams: {'threshold': 20},
      ),
      defaultPriority: WorkflowPriority.high,
    ),

    WorkflowTemplate(
      id: 'tpl_storage_check',
      title: 'Storage Monitor',
      titleId: 'Monitor Penyimpanan',
      description: 'Periodically check storage usage and alert if running low.',
      descriptionId: 'Cek penggunaan penyimpanan secara berkala.',
      icon: '💾',
      category: TemplateCategory.monitoring,
      defaultPrompt:
          'Cek status penyimpanan device saya. Jika tersisa kurang dari 2GB, '
          'berikan rekomendasi file atau cache yang bisa dibersihkan.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.interval,
        intervalMinutes: 720,
      ),
    ),

    // ─── Communication ────────────────────────────────────────────────────────
    WorkflowTemplate(
      id: 'tpl_notif_digest',
      title: 'Notification Digest',
      titleId: 'Ringkasan Notifikasi',
      description: 'Summarize unread notifications every few hours.',
      descriptionId: 'Ringkas notifikasi yang belum dibaca setiap beberapa jam.',
      icon: '🔔',
      category: TemplateCategory.communication,
      defaultPrompt:
          'Baca notifikasi terbaru saya dan buat ringkasan singkat. '
          'Kelompokkan berdasarkan prioritas: urgent, penting, dan bisa diabaikan.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.interval,
        intervalMinutes: 180,
      ),
    ),

    WorkflowTemplate(
      id: 'tpl_keyword_alert',
      title: 'Keyword Alert',
      titleId: 'Alert Kata Kunci',
      description: 'Get alerted when a notification contains a specific keyword.',
      descriptionId: 'Dapatkan alert saat notifikasi mengandung kata kunci tertentu.',
      icon: '🔍',
      category: TemplateCategory.communication,
      defaultPrompt:
          'Notifikasi penting terdeteksi mengandung kata kunci "{{keyword}}". '
          'Analisis konteksnya dan beri tahu saya apakah perlu tindakan segera.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.event,
        eventKind: EventTriggerKind.notificationKeyword,
        eventParams: {'keyword': 'urgent'},
      ),
      defaultVariables: {'keyword': 'urgent'},
      defaultPriority: WorkflowPriority.critical,
    ),

    // ─── Automation ───────────────────────────────────────────────────────────
    WorkflowTemplate(
      id: 'tpl_wifi_routine',
      title: 'WiFi Connected Routine',
      titleId: 'Rutinitas WiFi Terhubung',
      description: 'Run tasks automatically when connecting to WiFi.',
      descriptionId: 'Jalankan tugas otomatis saat terhubung ke WiFi.',
      icon: '📶',
      category: TemplateCategory.automation,
      defaultPrompt:
          'Saya baru terhubung ke WiFi. Cek apakah ada tugas yang tertunda '
          'yang membutuhkan koneksi internet, dan jalankan jika ada.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.event,
        eventKind: EventTriggerKind.wifiConnected,
      ),
    ),

    WorkflowTemplate(
      id: 'tpl_multi_step_report',
      title: 'Multi-Step Report',
      titleId: 'Laporan Multi-Langkah',
      description: 'Generate a report by gathering data from multiple sources.',
      descriptionId: 'Buat laporan dengan mengumpulkan data dari berbagai sumber.',
      icon: '📊',
      category: TemplateCategory.automation,
      defaultPrompt: 'Mulai proses pembuatan laporan.',
      defaultSteps: [
        WorkflowStep(
          id: 'gather_device',
          prompt: 'Kumpulkan informasi device: baterai, storage, dan koneksi.',
          timeoutSeconds: 30,
        ),
        WorkflowStep(
          id: 'gather_calendar',
          prompt: 'Ambil jadwal kalender untuk hari ini dan besok.',
          condition: "prev.isNotEmpty",
          timeoutSeconds: 30,
        ),
        WorkflowStep(
          id: 'compile_report',
          prompt: 'Kompilasi informasi berikut menjadi laporan ringkas dan simpan sebagai note:\n\nDevice: {{step_gather_device_result}}\nKalender: {{step_gather_calendar_result}}',
          condition: "prev.isNotEmpty",
          timeoutSeconds: 45,
        ),
      ],
      defaultTrigger: TriggerConfig(
        type: TriggerType.schedule,
        hour: 18,
        minute: 0,
        daysOfWeek: [5], // Friday only
      ),
      defaultTimeoutSeconds: 120,
    ),

    // ─── Health ───────────────────────────────────────────────────────────────
    WorkflowTemplate(
      id: 'tpl_break_reminder',
      title: 'Break Reminder',
      titleId: 'Pengingat Istirahat',
      description: 'Remind you to take breaks at regular intervals.',
      descriptionId: 'Ingatkan untuk istirahat secara berkala.',
      icon: '🧘',
      category: TemplateCategory.health,
      defaultPrompt:
          'Sudah waktunya istirahat! Berikan satu tips kesehatan singkat '
          'atau stretching exercise yang bisa dilakukan dalam 2 menit.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.interval,
        intervalMinutes: 90,
      ),
      defaultPriority: WorkflowPriority.low,
    ),

    WorkflowTemplate(
      id: 'tpl_charging_routine',
      title: 'Charging Night Routine',
      titleId: 'Rutinitas Charging Malam',
      description: 'Run a routine when you plug in your phone at night.',
      descriptionId: 'Jalankan rutinitas saat mencolokkan HP di malam hari.',
      icon: '🌙',
      category: TemplateCategory.health,
      defaultPrompt:
          'Device sedang di-charge. Buat ringkasan hari ini: '
          'apa yang sudah dicapai dan reminder untuk besok pagi.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.event,
        eventKind: EventTriggerKind.chargingStart,
      ),
    ),
  ];

  /// Get templates by category.
  static List<WorkflowTemplate> byCategory(TemplateCategory category) {
    return templates.where((t) => t.category == category).toList();
  }

  /// Get a template by ID.
  static WorkflowTemplate? byId(String id) {
    return templates.where((t) => t.id == id).firstOrNull;
  }
}
