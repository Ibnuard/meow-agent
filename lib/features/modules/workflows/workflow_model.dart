// Workflow Manager data models.

/// Trigger type for workflow execution.
enum TriggerType {
  schedule, // Exact time + day selection
  interval, // Every N minutes/hours
  event, // Event-based (battery low, notification, etc.)
}

/// Event trigger subtypes.
enum EventTriggerKind {
  batteryLow, // Battery drops below 50%
  batteryAbove, // Battery rises above 50%
  batteryFull, // Battery reaches 100%
  chargingStart, // Device plugged in
  chargingStop, // Device unplugged
  notificationKeyword, // Notification contains keyword
  appOpened, // Specific app opened
  wifiConnected, // Connected to WiFi
  wifiDisconnected, // Disconnected from WiFi
}

/// Notification style when workflow completes.
enum NotifStyle {
  silent, // No sound, no vibration
  normal, // Default notification sound
  alarm, // Full-screen intent, loud, wake screen
}

/// Priority level for workflow execution queue.
enum WorkflowPriority { low, normal, high, critical }

/// When the workflow should fire.
class TriggerConfig {
  const TriggerConfig({
    required this.type,
    this.hour,
    this.minute,
    this.daysOfWeek,
    this.intervalMinutes,
    this.eventKind,
    this.eventParams,
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

  /// Event kind for event-based triggers.
  final EventTriggerKind? eventKind;

  /// Additional params for event triggers (e.g. keyword, threshold, app package).
  final Map<String, dynamic>? eventParams;

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'hour': hour,
    'minute': minute,
    'daysOfWeek': daysOfWeek,
    'intervalMinutes': intervalMinutes,
    'eventKind': eventKind?.name,
    'eventParams': eventParams,
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
    eventKind: json['eventKind'] != null
        ? EventTriggerKind.values.firstWhere(
            (e) => e.name == json['eventKind'],
            orElse: () => EventTriggerKind.batteryLow,
          )
        : null,
    eventParams: (json['eventParams'] as Map<String, dynamic>?),
  );

  /// Human-readable summary of the trigger.
  String get summary {
    if (type == TriggerType.event) {
      return _eventSummary;
    }
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

  String get _eventSummary {
    switch (eventKind) {
      case EventTriggerKind.batteryLow:
        return 'Baterai < 50%';
      case EventTriggerKind.batteryAbove:
        return 'Baterai > 50%';
      case EventTriggerKind.batteryFull:
        return 'Baterai penuh';
      case EventTriggerKind.chargingStart:
        return 'Mulai charging';
      case EventTriggerKind.chargingStop:
        return 'Berhenti charging';
      case EventTriggerKind.notificationKeyword:
        final keyword = eventParams?['keyword'] ?? '?';
        return 'Notif: "$keyword"';
      case EventTriggerKind.appOpened:
        final app = eventParams?['appName'] ?? eventParams?['package'] ?? '?';
        return 'App: $app';
      case EventTriggerKind.wifiConnected:
        return 'WiFi terhubung';
      case EventTriggerKind.wifiDisconnected:
        return 'WiFi terputus';
      case null:
        return 'Event';
    }
  }
}

/// Notification configuration.
class NotifConfig {
  const NotifConfig({this.style = NotifStyle.normal, this.showResult = true});

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

/// A single step in a chained workflow.
class WorkflowStep {
  const WorkflowStep({
    required this.id,
    required this.prompt,
    this.agentId,
    this.condition,
    this.onFailure = StepFailureAction.stop,
    this.timeoutSeconds = 300,
  });

  final String id;
  final String prompt;
  final String? agentId;

  /// Optional condition to evaluate before running this step.
  /// Uses simple expressions: "prev.contains('success')", "prev.length > 0", etc.
  /// If null, step always runs.
  final String? condition;

  /// What to do if this step fails.
  final StepFailureAction onFailure;

  /// Timeout for this specific step in seconds.
  final int timeoutSeconds;

  Map<String, dynamic> toJson() => {
    'id': id,
    'prompt': prompt,
    'agentId': agentId,
    'condition': condition,
    'onFailure': onFailure.name,
    'timeoutSeconds': timeoutSeconds,
  };

  factory WorkflowStep.fromJson(Map<String, dynamic> json) => WorkflowStep(
    id: json['id'] as String? ?? '',
    prompt: json['prompt'] as String? ?? '',
    agentId: json['agentId'] as String?,
    condition: json['condition'] as String?,
    onFailure: StepFailureAction.values.firstWhere(
      (a) => a.name == json['onFailure'],
      orElse: () => StepFailureAction.stop,
    ),
    timeoutSeconds: json['timeoutSeconds'] as int? ?? 300,
  );
}

/// Action when a step fails.
enum StepFailureAction {
  stop, // Stop the entire chain
  skip, // Skip this step, continue to next
  retry, // Retry this step once
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
    this.allowSensitive = false,
    this.enabled = true,
    this.lastRun,
    this.lastResult,
    this.retryCount = 0,
    this.priority = WorkflowPriority.normal,
    this.timeoutSeconds = 60,
    this.steps = const [],
    this.variables = const {},
    this.templateId,
    required this.createdAt,
  });

  final String id;
  final String agentId;
  final String title;

  /// Main prompt (used if steps is empty — single-step mode).
  final String prompt;
  final TriggerConfig trigger;
  final NotifConfig notification;
  final bool sendToChat;

  /// Auto-approve sensitive/confirmation-required tool calls during execution.
  final bool allowSensitive;
  final bool enabled;
  final DateTime? lastRun;
  final String? lastResult;
  final int retryCount;

  /// Execution priority in the queue.
  final WorkflowPriority priority;

  /// Timeout in seconds for single-step mode. Ignored if steps are defined.
  final int timeoutSeconds;

  /// Ordered steps for chained workflow. If empty, uses single prompt mode.
  final List<WorkflowStep> steps;

  /// User-defined variables that get injected into prompt context.
  /// Keys are variable names, values are default values.
  /// At runtime, variables are expanded in prompts as {{varName}}.
  final Map<String, String> variables;

  /// If created from a template, stores the template ID.
  final String? templateId;

  /// Creation timestamp.
  final DateTime createdAt;

  /// Whether this is a chained (multi-step) workflow.
  bool get isChained => steps.isNotEmpty;

  WorkflowModel copyWith({
    String? agentId,
    String? title,
    String? prompt,
    TriggerConfig? trigger,
    NotifConfig? notification,
    bool? sendToChat,
    bool? allowSensitive,
    bool? enabled,
    DateTime? lastRun,
    String? lastResult,
    int? retryCount,
    WorkflowPriority? priority,
    int? timeoutSeconds,
    List<WorkflowStep>? steps,
    Map<String, String>? variables,
    String? templateId,
  }) => WorkflowModel(
    id: id,
    agentId: agentId ?? this.agentId,
    title: title ?? this.title,
    prompt: prompt ?? this.prompt,
    trigger: trigger ?? this.trigger,
    notification: notification ?? this.notification,
    sendToChat: sendToChat ?? this.sendToChat,
    allowSensitive: allowSensitive ?? this.allowSensitive,
    enabled: enabled ?? this.enabled,
    lastRun: lastRun ?? this.lastRun,
    lastResult: lastResult ?? this.lastResult,
    retryCount: retryCount ?? this.retryCount,
    priority: priority ?? this.priority,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    steps: steps ?? this.steps,
    variables: variables ?? this.variables,
    templateId: templateId ?? this.templateId,
    createdAt: createdAt,
  );
}

/// A serialized runtime event for a workflow execution.
class WorkflowExecutionEvent {
  const WorkflowExecutionEvent({
    required this.type,
    required this.message,
    required this.createdAt,
  });

  /// e.g. state_change, llm_decision, tool_call, tool_result, error, final_response.
  final String type;
  final String message;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'type': type,
    'message': message,
    'createdAt': createdAt.toIso8601String(),
  };

  factory WorkflowExecutionEvent.fromJson(Map<String, dynamic> json) =>
      WorkflowExecutionEvent(
        type: json['type'] as String? ?? '',
        message: json['message'] as String? ?? '',
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
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
    this.events = const [],
    this.stepResults = const [],
  });

  final int? id;
  final String workflowId;
  final String agentId;
  final String workflowTitle;
  final String status; // 'success' | 'failed' | 'timeout' | 'partial'
  final String result;
  final DateTime executedAt;
  final int? durationMs;
  final List<WorkflowExecutionEvent> events;

  /// Results from each step in a chained workflow.
  final List<StepResult> stepResults;
}

/// Result of a single step execution.
class StepResult {
  const StepResult({
    required this.stepId,
    required this.status,
    required this.result,
    this.durationMs,
  });

  final String stepId;
  final String status; // 'success' | 'failed' | 'skipped'
  final String result;
  final int? durationMs;

  Map<String, dynamic> toJson() => {
    'stepId': stepId,
    'status': status,
    'result': result,
    'durationMs': durationMs,
  };

  factory StepResult.fromJson(Map<String, dynamic> json) => StepResult(
    stepId: json['stepId'] as String? ?? '',
    status: json['status'] as String? ?? 'failed',
    result: json['result'] as String? ?? '',
    durationMs: json['durationMs'] as int?,
  );
}
