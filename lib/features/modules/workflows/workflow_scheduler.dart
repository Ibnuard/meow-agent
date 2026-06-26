import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/storage/app_settings_repository.dart';
import '../../../core/storage/local_storage_service.dart';
import '../../../core/storage/meow_database.dart';
import 'workflow_foreground_service.dart';
import 'workflow_model.dart';
import 'workflow_repository.dart';
import 'workflow_runner.dart';

/// Unique task name for WorkManager periodic workflows.
const workManagerTaskName = 'meow_workflow_interval';

/// Schedules workflows using AlarmManager (exact time) and WorkManager (intervals).
/// Event-based workflows are handled by WorkflowEventListener, not here.
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

    // Event-based workflows don't need AlarmManager/WorkManager scheduling.
    if (workflow.trigger.type == TriggerType.event) return;

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
      final nextFire = nextFireTime(workflow.trigger);
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
    } else if (workflow.trigger.type == TriggerType.schedule) {
      await AndroidAlarmManager.cancel(alarmId);
    }
    // Event-based workflows have no scheduled alarm to cancel.
  }

  /// Reschedule all enabled workflows (e.g., after reboot or app start).
  static Future<void> rescheduleAll() async {
    final repo = WorkflowRepository();
    final workflows = await repo.listEnabled();
    for (final wf in workflows) {
      await schedule(wf);
    }
  }

  /// Register a WorkManager periodic keep-alive task (L2 fallback).
  /// If the app process is killed, WorkManager fires every ~15 min and
  /// restarts the persistent foreground service via [_workManagerDispatcher].
  static Future<void> registerKeepAlive() async {
    final repo = WorkflowRepository();
    final hasEnabled = (await repo.listEnabled()).isNotEmpty;
    if (!hasEnabled) return;

    await Workmanager().registerPeriodicTask(
      'meow_keep_alive',
      'meow_keep_alive',
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.notRequired),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  /// Cancel the keep-alive task (when all workflows are disabled).
  static Future<void> cancelKeepAlive() async {
    await Workmanager().cancelByUniqueName('meow_keep_alive');
  }

  /// Calculate the next fire time for a schedule trigger.
  /// Made public so the dynamic runner can use it for smart timer calculation.
  static DateTime? nextFireTime(TriggerConfig trigger) {
    if (trigger.type != TriggerType.schedule) return null;

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

  /// Calculate the duration until the next workflow should fire.
  /// Used by WorkflowRunner for dynamic timer scheduling.
  static Duration? timeUntilNextFire(List<WorkflowModel> workflows) {
    final now = DateTime.now();
    Duration? shortest;

    for (final wf in workflows) {
      if (!wf.enabled) continue;
      if (wf.trigger.type == TriggerType.event) continue;

      Duration? untilFire;

      if (wf.trigger.type == TriggerType.interval) {
        final intervalSecs = (wf.trigger.intervalMinutes ?? 60) * 60;
        final lastTime = wf.lastRun ?? wf.createdAt;
        final elapsed = now.difference(lastTime).inSeconds;
        final remaining = intervalSecs - elapsed;
        untilFire = Duration(seconds: remaining > 0 ? remaining : 0);
      } else if (wf.trigger.type == TriggerType.schedule) {
        final next = nextFireTime(wf.trigger);
        if (next != null) {
          untilFire = next.difference(now);
          if (untilFire.isNegative) untilFire = Duration.zero;
        }
      }

      if (untilFire != null) {
        if (shortest == null || untilFire < shortest) {
          shortest = untilFire;
        }
      }
    }

    return shortest;
  }
}

/// Top-level callback for AlarmManager (must be static/top-level).
/// Runs in a separate isolate — executes due workflows and reschedules.
@pragma('vm:entry-point')
Future<void> _alarmCallback() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Create standalone local storage using SQLite settings
  final db = MeowDatabase.instance;
  final settingsRepo = AppSettingsRepository(db);
  final allSettings = await settingsRepo.getAll();
  final storage = LocalStorageService(settingsRepo, allSettings);

  final container = ProviderContainer(
    overrides: [
      localStorageProvider.overrideWithValue(storage),
    ],
  );

  // Execute due workflows
  final runner = container.read(workflowRunnerProvider);
  await runner.checkAndRun();
  await runner.waitUntilIdle();

  // Reschedule next schedule occurrence
  final repo = WorkflowRepository();
  final workflows = await repo.listEnabled();
  for (final wf in workflows) {
    if (wf.trigger.type != TriggerType.schedule) continue;
    await WorkflowScheduler.schedule(wf);
  }

  // Ensure persistent foreground service is alive
  await WorkflowForegroundService.ensureRunning();
}

/// Top-level WorkManager dispatcher.
/// Runs in background isolates. Executes interval workflows or keep-alive checks.
@pragma('vm:entry-point')
void _workManagerDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    await WorkflowForegroundService.ensureRunning();

    // Create standalone local storage using SQLite settings
    final db = MeowDatabase.instance;
    final settingsRepo = AppSettingsRepository(db);
    final allSettings = await settingsRepo.getAll();
    final storage = LocalStorageService(settingsRepo, allSettings);

    final container = ProviderContainer(
      overrides: [
        localStorageProvider.overrideWithValue(storage),
      ],
    );

    final runner = container.read(workflowRunnerProvider);

    if (taskName == 'meow_keep_alive') {
      await runner.checkAndRun();
    } else {
      final workflowId = inputData?['workflowId'] as String?;
      if (workflowId != null) {
        final repo = WorkflowRepository();
        final wf = await repo.read(workflowId);
        if (wf != null && wf.enabled) {
          runner.enqueue(wf);
        }
      } else {
        await runner.checkAndRun();
      }
    }

    await runner.waitUntilIdle();
    return true;
  });
}
