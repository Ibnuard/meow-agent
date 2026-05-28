import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Notification service for workflow execution results.
class WorkflowNotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  // Notification channel IDs.
  static const _channelSilent = 'workflow_silent';
  static const _channelNormal = 'workflow_normal';
  static const _channelAlarm = 'workflow_alarm';

  /// Initialize the notification plugin and channels, and request permissions.
  static Future<void> initialize({
    void Function(NotificationResponse)? onTap,
  }) async {
    if (_initialized) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    final settings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: onTap,
    );

    // Request POST_NOTIFICATIONS permission on Android 13+.
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.requestNotificationsPermission();
      await androidPlugin.requestExactAlarmsPermission();
    }

    _initialized = true;
  }

  /// Show a workflow result notification.
  static Future<void> show({
    required int id,
    required String title,
    required String body,
    required String style, // 'silent' | 'normal' | 'alarm'
    String? payload,
    bool ongoing = false,
  }) async {
    final channelId = _channelIdFor(style);
    final channelName = _channelNameFor(style);
    final importance = _importanceFor(style);
    final priority = _priorityFor(style);

    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: 'Meow Agent workflow notifications ($style)',
      importance: importance,
      priority: priority,
      playSound: !ongoing && style != 'silent',
      enableVibration: !ongoing && style != 'silent',
      fullScreenIntent: !ongoing && style == 'alarm',
      ongoing: ongoing,
      autoCancel: !ongoing,
      onlyAlertOnce: ongoing,
      // Alarm mode: aggressive vibration pattern + insistent to keep alerting.
      vibrationPattern: style == 'alarm' && !ongoing
          ? Int64List.fromList([0, 500, 200, 500, 200, 500, 200, 1000])
          : null,
      enableLights: style == 'alarm',
      ledColor: const Color(0xFF3B82F6),
      ledOnMs: 1000,
      ledOffMs: 500,
      category: style == 'alarm'
          ? AndroidNotificationCategory.alarm
          : AndroidNotificationCategory.reminder,
      styleInformation: BigTextStyleInformation(body),
    );

    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(id, title, body, details, payload: payload);
  }

  /// Cancel a specific notification.
  static Future<void> cancel(int id) async {
    await _plugin.cancel(id);
  }

  static String _channelIdFor(String style) {
    switch (style) {
      case 'silent':
        return _channelSilent;
      case 'alarm':
        return _channelAlarm;
      default:
        return _channelNormal;
    }
  }

  static String _channelNameFor(String style) {
    switch (style) {
      case 'silent':
        return 'Workflow (Silent)';
      case 'alarm':
        return 'Workflow (Alarm)';
      default:
        return 'Workflow';
    }
  }

  static Importance _importanceFor(String style) {
    switch (style) {
      case 'silent':
        return Importance.low;
      case 'alarm':
        return Importance.max;
      default:
        return Importance.high;
    }
  }

  static Priority _priorityFor(String style) {
    switch (style) {
      case 'silent':
        return Priority.low;
      case 'alarm':
        return Priority.max;
      default:
        return Priority.high;
    }
  }
}
