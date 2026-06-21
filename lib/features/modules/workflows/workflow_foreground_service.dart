import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'workflow_repository.dart';

/// Foreground service manager for workflow execution.
/// Uses a persistent notification to keep the app process alive,
/// preventing Android from killing it.
///
/// Two modes:
/// - **Scheduler mode** (persistent): stays alive as long as ≥1 workflow is
///   enabled, even when no workflow is actively executing. This prevents the
///   OS from killing the process between runs.
/// - **Execution mode** (transient): shown while a workflow is actively
///   running, with progress text.
class WorkflowForegroundService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _channelId = 'workflow_foreground';
  static const _channelName = 'Workflow Service';
  static const _notifId = 99999;

  static bool _active = false;
  static bool _persistentMode = false;
  static bool _pluginInitialized = false;
  static int _activeWorkflows = 0;
  static Timer? _autoStopTimer;

  /// Whether the foreground service is currently active (any mode).
  static bool get isActive => _active;

  /// Whether the service is in persistent scheduler mode.
  static bool get isPersistent => _persistentMode;

  /// Ensure the notification plugin is initialized before use.
  static Future<void> _ensureInitialized() async {
    if (_pluginInitialized) return;
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: androidSettings));
    _pluginInitialized = true;
  }

  // ─── Persistent Scheduler Mode ──────────────────────────────────────────

  /// Start persistent scheduler mode. Keeps the process alive as long as
  /// there are enabled workflows. Call this on app start and when workflows
  /// are toggled.
  static Future<void> ensureSchedulerRunning() async {
    final repo = WorkflowRepository();
    final hasEnabled = (await repo.listEnabled()).isNotEmpty;

    if (hasEnabled && !_persistentMode) {
      await _startPersistent();
    } else if (!hasEnabled && _persistentMode && _activeWorkflows <= 0) {
      await _stopPersistent();
    }
  }

  /// Force-start the persistent scheduler (used by WorkManager restart).
  static Future<void> ensureRunning() async {
    if (!_active) {
      await _startPersistent();
    }
  }

  static Future<void> _startPersistent() async {
    await _ensureInitialized();
    _persistentMode = true;
    _active = true;
    _autoStopTimer?.cancel();

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription:
          'Keeps Meow Agent alive for scheduled workflow execution.',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      playSound: false,
      enableVibration: false,
      showWhen: false,
      silent: true,
      category: AndroidNotificationCategory.service,
    );

    await _plugin.show(
      _notifId,
      'Meow Agent',
      'Workflow scheduler active',
      NotificationDetails(android: androidDetails),
    );
  }

  static Future<void> _stopPersistent() async {
    if (!_persistentMode) return;
    _persistentMode = false;
    if (_activeWorkflows <= 0) {
      _active = false;
      await _ensureInitialized();
      await _plugin.cancel(_notifId);
    }
  }

  // ─── Execution Mode (transient, during active workflow run) ─────────────

  /// Start execution mode. Call before executing workflows.
  static Future<void> start({String? workflowTitle}) async {
    await _ensureInitialized();
    _activeWorkflows++;
    _autoStopTimer?.cancel();

    if (_active) {
      // Already have a notification — just update text.
      await _updateNotification(workflowTitle: workflowTitle);
      return;
    }

    _active = true;

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

    await _plugin.show(
      _notifId,
      'Meow Agent — Workflow Active',
      _buildBody(workflowTitle),
      NotificationDetails(android: androidDetails),
    );
  }

  /// Notify that a workflow has completed.
  /// Falls back to persistent scheduler mode if enabled, otherwise stops.
  static Future<void> onWorkflowComplete() async {
    _activeWorkflows--;
    if (_activeWorkflows <= 0) {
      _activeWorkflows = 0;
      // Delay slightly to batch rapid completions.
      _autoStopTimer?.cancel();
      _autoStopTimer = Timer(const Duration(seconds: 5), () async {
        if (_persistentMode) {
          // Return to idle scheduler notification.
          await _updateNotification();
        } else {
          await stop();
        }
      });
    } else {
      await _updateNotification();
    }
  }

  /// Force stop all modes.
  static Future<void> stop() async {
    if (!_active) return;
    _active = false;
    _persistentMode = false;
    _activeWorkflows = 0;
    _autoStopTimer?.cancel();
    await _ensureInitialized();
    await _plugin.cancel(_notifId);
  }

  static Future<void> _updateNotification({String? workflowTitle}) async {
    if (!_active) return;
    await _ensureInitialized();

    final isExecuting = _activeWorkflows > 0;
    final title = isExecuting
        ? 'Meow Agent — Workflow Active'
        : 'Meow Agent';
    final body = isExecuting
        ? _buildBody(workflowTitle)
        : 'Workflow scheduler active';

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
      silent: true,
      category: AndroidNotificationCategory.service,
    );

    await _plugin.show(
      _notifId,
      title,
      body,
      NotificationDetails(android: androidDetails),
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
