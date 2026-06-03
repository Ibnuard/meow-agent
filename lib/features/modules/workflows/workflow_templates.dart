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
    this.defaultTimeoutSeconds = 300,
    this.defaultNotification = const NotifConfig(),
    this.defaultSendToChat = false,
    this.defaultAllowSensitive = false,
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
  final NotifConfig defaultNotification;
  final bool defaultSendToChat;
  final bool defaultAllowSensitive;
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
    //
    // 1. Morning Briefing — schedule trigger, @date / @day_name / @chat_history
    WorkflowTemplate(
      id: 'tpl_morning_briefing',
      title: 'Morning Briefing',
      titleId: 'Briefing Pagi',
      description:
          'Get a concise daily briefing with calendar, reminders, and top priorities.',
      descriptionId:
          'Dapatkan briefing harian dengan jadwal, pengingat, dan prioritas utama.',
      icon: '🌅',
      category: TemplateCategory.productivity,
      defaultPrompt:
          'Today is @day_name, @date_long. Give me a concise morning briefing '
          'covering: 1) key calendar events and reminders from @chat_history, '
          '2) weather-sensitive items I should know, 3) top 3 priorities I '
          'should focus on today. Keep it actionable and concise.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.schedule,
        hour: 7,
        minute: 0,
        daysOfWeek: [1, 2, 3, 4, 5],
      ),
    ),

    // 2. Daily Journal — schedule trigger, 2 chained steps with @date / @prev
    WorkflowTemplate(
      id: 'tpl_daily_journal',
      title: 'Daily Journal',
      titleId: 'Jurnal Harian',
      description:
          'Generate reflective journal prompts and save them as notes each evening.',
      descriptionId:
          'Buat prompt refleksi jurnal dan simpan sebagai catatan setiap malam.',
      icon: '📓',
      category: TemplateCategory.productivity,
      defaultPrompt:
          'It is @day_name evening, @datetime. Create 3 thoughtful journal '
          'prompts about today\'s experiences, challenges, and lessons learned.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.schedule,
        hour: 21,
        minute: 0,
        daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
      ),
      defaultSteps: [
        WorkflowStep(
          id: 'generate_prompt',
          prompt:
              'It\'s @day_name evening, @datetime. Based on @chat_history, '
              'create 3 thoughtful journal prompts about today\'s experiences, '
              'challenges faced, and lessons learned.',
          timeoutSeconds: 300,
        ),
        WorkflowStep(
          id: 'save_note',
          prompt:
              'Save the following journal prompts as a note titled '
              '"Journal @date":\n\n@prev',
          condition: 'prev.isNotEmpty',
          timeoutSeconds: 300,
        ),
      ],
    ),

    // ─── Monitoring ──────────────────────────────────────────────────────────
    //
    // 3. Battery Guardian — event trigger, @battery_level, high priority, alarm
    WorkflowTemplate(
      id: 'tpl_battery_guardian',
      title: 'Battery Guardian',
      titleId: 'Penjaga Baterai',
      description:
          'Get power-saving tips when battery drops below threshold.',
      descriptionId:
          'Dapatkan tips hemat baterai saat daya tersisa sedikit.',
      icon: '🔋',
      category: TemplateCategory.monitoring,
      defaultPrompt:
          'Battery is at @battery_level%. List the top power-draining suspects '
          'and give me 3 specific actions I can take right now to extend '
          'battery life.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.event,
        eventKind: EventTriggerKind.batteryLow,
      ),
      defaultPriority: WorkflowPriority.high,
      defaultNotification: NotifConfig(
        style: NotifStyle.alarm,
        showResult: true,
      ),
      defaultAllowSensitive: true,
    ),

    // 4. Storage Health Monitor — interval trigger, @datetime, low priority
    WorkflowTemplate(
      id: 'tpl_storage_health',
      title: 'Storage Health Monitor',
      titleId: 'Monitor Penyimpanan',
      description:
          'Periodically check storage and suggest cleanup when space is low.',
      descriptionId:
          'Periksa penyimpanan secara berkala dan sarankan pembersihan.',
      icon: '💾',
      category: TemplateCategory.monitoring,
      defaultPrompt:
          'Check device storage as of @datetime. If free space is under 2GB, '
          'recommend specific files, caches, or apps I can safely clean up '
          'to reclaim space.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.interval,
        intervalMinutes: 720,
      ),
      defaultPriority: WorkflowPriority.low,
    ),

    // ─── Communication ───────────────────────────────────────────────────────
    //
    // 5. Notification Digest — interval trigger, @notif_title / @notif_app,
    //    sendToChat: true
    WorkflowTemplate(
      id: 'tpl_notification_digest',
      title: 'Notification Digest',
      titleId: 'Ringkasan Notifikasi',
      description:
          'Summarize recent notifications grouped by priority every few hours.',
      descriptionId:
          'Ringkas notifikasi terbaru berdasarkan prioritas setiap beberapa jam.',
      icon: '🔔',
      category: TemplateCategory.communication,
      defaultPrompt:
          'Summarize recent notifications grouped by priority:\n'
          '@notif_title — @notif_app\n\n'
          'Categorize each as: urgent (needs action now), important (needs '
          'attention today), or informational (can wait). Flag anything that '
          'needs a reply.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.interval,
        intervalMinutes: 180,
      ),
      defaultSendToChat: true,
    ),

    // 6. Urgent Alert — notificationKeyword event, @notif_keyword / @notif_body,
    //    critical priority, alarm notification
    WorkflowTemplate(
      id: 'tpl_urgent_alert',
      title: 'Urgent Alert',
      titleId: 'Alert Penting',
      description:
          'Get an urgent alert when a notification contains a specific keyword.',
      descriptionId:
          'Dapatkan peringatan saat notifikasi mengandung kata kunci tertentu.',
      icon: '🔍',
      category: TemplateCategory.communication,
      defaultPrompt:
          'URGENT notification matched keyword "@notif_keyword":\n'
          '- App: @notif_app\n'
          '- Title: @notif_title\n'
          '- Body: @notif_body\n\n'
          'Analyze this notification and tell me if immediate action is needed. '
          'If yes, suggest the next step.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.event,
        eventKind: EventTriggerKind.notificationKeyword,
        eventParams: {'keyword': 'urgent'},
      ),
      defaultVariables: {'keyword': 'urgent'},
      defaultPriority: WorkflowPriority.critical,
      defaultNotification: NotifConfig(
        style: NotifStyle.alarm,
        showResult: true,
      ),
      defaultAllowSensitive: true,
    ),

    // ─── Automation ──────────────────────────────────────────────────────────
    //
    // 7. WiFi Context Switch — wifiConnected event, @wifi_name variable
    WorkflowTemplate(
      id: 'tpl_wifi_context',
      title: 'WiFi Context Switch',
      titleId: 'Saklar Konteks WiFi',
      description:
          'Run pending sync tasks automatically when connected to WiFi.',
      descriptionId:
          'Jalankan tugas sinkronisasi otomatis saat terhubung ke WiFi.',
      icon: '📶',
      category: TemplateCategory.automation,
      defaultPrompt:
          'Connected to WiFi. Check if there are any pending sync tasks, '
          'delayed messages, or queued actions that require internet '
          'connectivity, and execute them now.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.event,
        eventKind: EventTriggerKind.wifiConnected,
      ),
    ),

    // 8. Weekly Performance Report — schedule (Fri), 3 chained steps,
    //    @step1 / @step2 / @prev / @date_long
    WorkflowTemplate(
      id: 'tpl_weekly_report',
      title: 'Weekly Performance Report',
      titleId: 'Laporan Mingguan',
      description:
          'Generate a weekly report by gathering device data and chat context.',
      descriptionId:
          'Buat laporan mingguan dengan data perangkat dan konteks chat.',
      icon: '📊',
      category: TemplateCategory.automation,
      defaultPrompt: 'Start the weekly performance report generation.',
      defaultSteps: [
        WorkflowStep(
          id: 'gather_device',
          prompt:
              'Collect device health snapshot: battery trend, storage usage, '
              'and any error logs from this week.',
          timeoutSeconds: 300,
        ),
        WorkflowStep(
          id: 'gather_context',
          prompt:
              'From @chat_history, summarize this week\'s key conversations, '
              'completed tasks, and unresolved items.',
          condition: 'prev.isNotEmpty',
          timeoutSeconds: 300,
        ),
        WorkflowStep(
          id: 'compile_report',
          prompt:
              'Compile a weekly report from the data below. Save it as a note '
              'titled "Weekly Report — @date_long".\n\n'
              '## Device Health\n@step1\n\n'
              '## Weekly Summary\n@step2',
          condition: 'prev.isNotEmpty',
          timeoutSeconds: 300,
        ),
      ],
      defaultTrigger: TriggerConfig(
        type: TriggerType.schedule,
        hour: 18,
        minute: 0,
        daysOfWeek: [5],
      ),
    ),

    // ─── Health ──────────────────────────────────────────────────────────────
    //
    // 9. Mindful Break — interval trigger, @time / @day_name / @date,
    //    low priority, silent notification
    WorkflowTemplate(
      id: 'tpl_mindful_break',
      title: 'Mindful Break',
      titleId: 'Istirahat Sadar',
      description:
          'Gently remind you to take a break with a quick mindfulness exercise.',
      descriptionId:
          'Ingatkan untuk beristirahat dengan latihan mindfulness singkat.',
      icon: '🧘',
      category: TemplateCategory.health,
      defaultPrompt:
          'It\'s @time on @day_name (@date). Gently remind me to take a '
          'break. Suggest a 2-minute mindfulness exercise: either a breathing '
          'technique, a quick stretch, or a gratitude reflection based on '
          'something from @chat_history today.',
      defaultTrigger: TriggerConfig(
        type: TriggerType.interval,
        intervalMinutes: 120,
      ),
      defaultPriority: WorkflowPriority.low,
      defaultNotification: NotifConfig(
        style: NotifStyle.silent,
        showResult: false,
      ),
    ),

    // 10. Night Wind-Down — chargingStart event, 2 chained steps,
    //     @day_name / @date_long / @time / @chat_history / @prev,
    //     silent notification
    WorkflowTemplate(
      id: 'tpl_night_wind_down',
      title: 'Night Wind-Down',
      titleId: 'Relaksasi Malam',
      description:
          'Summarize your day and suggest focus areas for tomorrow at bedtime.',
      descriptionId:
          'Ringkas hari ini dan sarankan fokus untuk besok saat tidur.',
      icon: '🌙',
      category: TemplateCategory.health,
      defaultPrompt:
          'Device just started charging. Prepare a day summary and '
          'tomorrow\'s plan.',
      defaultSteps: [
        WorkflowStep(
          id: 'summarize_day',
          prompt:
              'Device just started charging at @time on @day_name (@date_long). '
              'Briefly summarize what I accomplished today based on '
              '@chat_history. Focus on completed tasks and meaningful '
              'interactions. Be warm and encouraging.',
          timeoutSeconds: 300,
        ),
        WorkflowStep(
          id: 'plan_tomorrow',
          prompt:
              'Using the summary below, suggest 3 focus areas for tomorrow. '
              'Keep each suggestion to one sentence.\n\n@prev',
          condition: 'prev.isNotEmpty',
          timeoutSeconds: 300,
        ),
      ],
      defaultTrigger: TriggerConfig(
        type: TriggerType.event,
        eventKind: EventTriggerKind.chargingStart,
      ),
      defaultNotification: NotifConfig(
        style: NotifStyle.silent,
        showResult: false,
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