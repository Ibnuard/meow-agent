import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:workmanager/workmanager.dart';

import 'workflow_model.dart';
import 'workflow_repository.dart';

/// Unique task name for WorkManager periodic workflows.
const workManagerTaskName = 'meow_workflow_interval';

/// Schedules workflows using AlarmManager (exact time) and WorkManager (intervals).
/// Notification delivery is handled separately by WorkflowNotificationService.
class WorkflowScheduler {
  static bool _initialized = false;

  /// Initialize AlarmManager, WorkManager, and timezone data.
  static Future<void> initialize() async {
    if (_initialized) return;
    await AndroidAlarmManager.initialize();
    await Workmanager().initialize(_workManagerDispatcher);
    _initialized = true;
  }

  /// Schedule a workflow based on its trigger config.
  static Future<void> schedule(WorkflowModel workflow) async {
    if (!workflow.enabled) return;

    final alarmId = workflow.id.hashCode.abs() % 2147483647;

    if (workflow.trigger.type == TriggerType.interval) {
      // Use WorkManager for interval-based workflows.
      final minutes = workflow.trigger.intervalMinutes ?? 60;
      await Workmanager().registerPeriodicTask(
        'wf_${workflow.id}',
        workManagerTaskName,
        frequency: Duration(minutes: minutes),
        inputData: {'workflowId': workflow.id},
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
      );
    } else {
      // Use AlarmManager for schedule-based (exact time) workflows.
      final nextFire = _nextFireTime(workflow.trigger);
      if (nextFire == null) return;

      await AndroidAlarmManager.oneShotAt(
        nextFire,
        alarmId,
        _alarmCallback,
        exact: true,
        wakeup: true,
        rescheduleOnReboot: true,
      );
    }
  }

  /// Cancel a scheduled workflow.
  static Future<void> cancel(WorkflowModel workflow) async {
    final alarmId = workflow.id.hashCode.abs() % 2147483647;

    if (workflow.trigger.type == TriggerType.interval) {
      await Workmanager().cancelByUniqueName('wf_${workflow.id}');
    } else {
      await AndroidAlarmManager.cancel(alarmId);
    }
  }

  /// Reschedule all enabled workflows (e.g., after reboot or app start).
  static Future<void> rescheduleAll() async {
    final repo = WorkflowRepository();
    final workflows = await repo.listEnabled();
    for (final wf in workflows) {
      await schedule(wf);
    }
  }

  /// Calculate the next fire time for a schedule trigger.
  static DateTime? _nextFireTime(TriggerConfig trigger) {
    final now = DateTime.now();
    final hour = trigger.hour ?? 0;
    final minute = trigger.minute ?? 0;

    // Today at the specified time.
    var candidate = DateTime(now.year, now.month, now.day, hour, minute);

    // If already passed today, start from tomorrow.
    if (candidate.isBefore(now) || candidate.isAtSameMomentAs(now)) {
      candidate = candidate.add(const Duration(days: 1));
    }

    // If specific days of week are set, find the next matching day.
    if (trigger.daysOfWeek != null && trigger.daysOfWeek!.isNotEmpty) {
      for (var i = 0; i < 7; i++) {
        final check = candidate.add(Duration(days: i));
        if (trigger.daysOfWeek!.contains(check.weekday)) {
          return DateTime(check.year, check.month, check.day, hour, minute);
        }
      }
      return null;
    }

    return candidate;
  }
}

/// Top-level callback for AlarmManager (must be static/top-level).
/// Note: This runs in a separate isolate without access to RuntimeEngine.
/// Actual execution is handled by WorkflowRunner in the main isolate.
/// This callback only reschedules the next occurrence.
@pragma('vm:entry-point')
Future<void> _alarmCallback() async {
  final repo = WorkflowRepository();
  final workflows = await repo.listEnabled();

  for (final wf in workflows) {
    if (wf.trigger.type != TriggerType.schedule) continue;
    // Reschedule for next occurrence so the alarm keeps firing.
    await WorkflowScheduler.schedule(wf);
  }
}

/// Top-level WorkManager dispatcher.
/// Same limitation as the alarm callback: cannot access RuntimeEngine
/// from a background isolate. Actual execution is handled by WorkflowRunner.
@pragma('vm:entry-point')
void _workManagerDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    return true;
  });
}
