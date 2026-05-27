import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Foreground service manager for workflow execution.
/// Uses a persistent notification to keep the app process alive
/// during workflow execution, preventing Android from killing it.
class WorkflowForegroundService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _channelId = 'workflow_foreground';
  static const _channelName = 'Workflow Service';
  static const _notifId = 99999;

  static bool _active = false;
  static int _activeWorkflows = 0;
  static Timer? _autoStopTimer;

  /// Whether the foreground service is currently active.
  static bool get isActive => _active;

  /// Start the foreground service notification.
  /// Call this before executing workflows to prevent process death.
  static Future<void> start({String? workflowTitle}) async {
    _activeWorkflows++;
    if (_active) {
      // Update the notification body with current count.
      await _updateNotification();
      return;
    }

    _active = true;
    _autoStopTimer?.cancel();

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Keeps Meow Agent alive during workflow execution.',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      playSound: false,
      enableVibration: false,
      showWhen: false,
      category: AndroidNotificationCategory.service,
      styleInformation: const BigTextStyleInformation(
        'Workflow sedang berjalan di background...',
      ),
    );

    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      _notifId,
      'Meow Agent — Workflow Active',
      _buildBody(workflowTitle),
      details,
    );
  }

  /// Notify that a workflow has completed.
  /// Automatically stops the service when all workflows are done.
  static Future<void> onWorkflowComplete() async {
    _activeWorkflows--;
    if (_activeWorkflows <= 0) {
      _activeWorkflows = 0;
      // Delay stop by 5 seconds to batch rapid completions.
      _autoStopTimer?.cancel();
      _autoStopTimer = Timer(const Duration(seconds: 5), () => stop());
    } else {
      await _updateNotification();
    }
  }

  /// Force stop the foreground service.
  static Future<void> stop() async {
    if (!_active) return;
    _active = false;
    _activeWorkflows = 0;
    _autoStopTimer?.cancel();
    await _plugin.cancel(_notifId);
  }

  static Future<void> _updateNotification() async {
    if (!_active) return;

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Keeps Meow Agent alive during workflow execution.',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      playSound: false,
      enableVibration: false,
      showWhen: false,
      onlyAlertOnce: true,
      category: AndroidNotificationCategory.service,
    );

    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      _notifId,
      'Meow Agent — Workflow Active',
      _buildBody(null),
      details,
    );
  }

  static String _buildBody(String? workflowTitle) {
    if (_activeWorkflows <= 1 && workflowTitle != null) {
      return 'Menjalankan: $workflowTitle';
    }
    if (_activeWorkflows > 1) {
      return '$_activeWorkflows workflow sedang berjalan...';
    }
    return 'Workflow sedang berjalan di background...';
  }
}
