// Workflow Manager data models.

/// Trigger type for workflow execution.
enum TriggerType {
  schedule, // Exact time + day selection
  interval, // Every N minutes/hours
}

/// Notification style when workflow completes.
enum NotifStyle {
  silent, // No sound, no vibration
  normal, // Default notification sound
  alarm, // Full-screen intent, loud, wake screen
}

/// When the workflow should fire.
class TriggerConfig {
  const TriggerConfig({
    required this.type,
    this.hour,
    this.minute,
    this.daysOfWeek,
    this.intervalMinutes,
  });

  final TriggerType type;

  /// Hour (0-23) for schedule triggers.
  final int? hour;

  /// Minute (0-59) for schedule triggers.
  final int? minute;

  /// Days of week (1=Mon..7=Sun). Null = every day.
  final List<int>? daysOfWeek;

  /// Interval in minutes for interval triggers.
  final int? intervalMinutes;

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'hour': hour,
        'minute': minute,
        'daysOfWeek': daysOfWeek,
        'intervalMinutes': intervalMinutes,
      };

  factory TriggerConfig.fromJson(Map<String, dynamic> json) => TriggerConfig(
        type: TriggerType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => TriggerType.schedule,
        ),
        hour: json['hour'] as int?,
        minute: json['minute'] as int?,
        daysOfWeek: (json['daysOfWeek'] as List?)?.cast<int>(),
        intervalMinutes: json['intervalMinutes'] as int?,
      );

  /// Human-readable summary of the trigger.
  String get summary {
    if (type == TriggerType.interval) {
      if (intervalMinutes == null) return 'Interval';
      if (intervalMinutes! >= 60) {
        final h = intervalMinutes! ~/ 60;
        final m = intervalMinutes! % 60;
        return m > 0 ? 'Setiap ${h}j ${m}m' : 'Setiap $h jam';
      }
      return 'Setiap $intervalMinutes menit';
    }
    // Schedule.
    final timeStr =
        '${(hour ?? 0).toString().padLeft(2, '0')}:${(minute ?? 0).toString().padLeft(2, '0')}';
    if (daysOfWeek == null || daysOfWeek!.length == 7) {
      return 'Setiap hari $timeStr';
    }
    const dayNames = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
    final days = daysOfWeek!.map((d) => dayNames[d - 1]).join(', ');
    return '$days $timeStr';
  }
}

/// Notification configuration.
class NotifConfig {
  const NotifConfig({
    this.style = NotifStyle.normal,
    this.showResult = true,
  });

  final NotifStyle style;

  /// Whether to show the agent's response in the notification body.
  final bool showResult;

  Map<String, dynamic> toJson() => {
        'style': style.name,
        'showResult': showResult,
      };

  factory NotifConfig.fromJson(Map<String, dynamic> json) => NotifConfig(
        style: NotifStyle.values.firstWhere(
          (s) => s.name == json['style'],
          orElse: () => NotifStyle.normal,
        ),
        showResult: json['showResult'] as bool? ?? true,
      );
}

/// A single workflow definition.
class WorkflowModel {
  const WorkflowModel({
    required this.id,
    required this.agentId,
    required this.title,
    required this.prompt,
    required this.trigger,
    this.notification = const NotifConfig(),
    this.sendToChat = false,
    this.enabled = true,
    this.lastRun,
    this.lastResult,
    this.retryCount = 0,
    required this.createdAt,
  });

  final String id;
  final String agentId;
  final String title;
  final String prompt;
  final TriggerConfig trigger;
  final NotifConfig notification;
  final bool sendToChat;
  final bool enabled;
  final DateTime? lastRun;
  final String? lastResult;
  final int retryCount;
  final DateTime createdAt;

  WorkflowModel copyWith({
    String? agentId,
    String? title,
    String? prompt,
    TriggerConfig? trigger,
    NotifConfig? notification,
    bool? sendToChat,
    bool? enabled,
    DateTime? lastRun,
    String? lastResult,
    int? retryCount,
  }) =>
      WorkflowModel(
        id: id,
        agentId: agentId ?? this.agentId,
        title: title ?? this.title,
        prompt: prompt ?? this.prompt,
        trigger: trigger ?? this.trigger,
        notification: notification ?? this.notification,
        sendToChat: sendToChat ?? this.sendToChat,
        enabled: enabled ?? this.enabled,
        lastRun: lastRun ?? this.lastRun,
        lastResult: lastResult ?? this.lastResult,
        retryCount: retryCount ?? this.retryCount,
        createdAt: createdAt,
      );
}

/// A single execution history entry.
class WorkflowExecution {
  const WorkflowExecution({
    this.id,
    required this.workflowId,
    required this.agentId,
    required this.workflowTitle,
    required this.status,
    required this.result,
    required this.executedAt,
    this.durationMs,
  });

  final int? id;
  final String workflowId;
  final String agentId;
  final String workflowTitle;
  final String status; // 'success' | 'failed' | 'timeout'
  final String result;
  final DateTime executedAt;
  final int? durationMs;
}
