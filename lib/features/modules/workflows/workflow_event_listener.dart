import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notification_intelligence/notification_models.dart';
import '../notification_intelligence/notification_service.dart';
import 'workflow_model.dart';
import 'workflow_repository.dart';
import 'workflow_runner.dart';

/// Listens for device events and triggers matching event-based workflows.
class WorkflowEventListener {
  WorkflowEventListener(this._ref);

  final Ref _ref;
  final WorkflowRepository _repo = WorkflowRepository();
  final Battery _battery = Battery();

  StreamSubscription<BatteryState>? _batteryStateSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<NotificationInfo>? _notificationSub;
  Timer? _batteryLevelTimer;

  int _lastBatteryLevel = -1;
  bool _wasCharging = false;
  bool _wasConnected = false;

  /// Cooldown tracking to prevent rapid re-firing.
  final Map<String, DateTime> _lastFired = {};
  static const _cooldown = Duration(minutes: 5);

  /// Start listening for device events.
  void start() {
    _listenBattery();
    _listenConnectivity();
    _listenNotifications();
  }

  /// Stop all listeners.
  void stop() {
    _batteryStateSub?.cancel();
    _connectivitySub?.cancel();
    _notificationSub?.cancel();
    _batteryLevelTimer?.cancel();
    _batteryStateSub = null;
    _connectivitySub = null;
    _notificationSub = null;
    _batteryLevelTimer = null;
  }

  // ─── Battery Events ─────────────────────────────────────────────────────────

  void _listenBattery() {
    // Monitor charging state changes.
    _batteryStateSub = _battery.onBatteryStateChanged.listen((state) {
      final isCharging = state == BatteryState.charging ||
          state == BatteryState.full;

      if (isCharging && !_wasCharging) {
        _fireEvent(
          EventTriggerKind.chargingStart,
          triggerVars: _batteryTriggerVars(),
        );
      } else if (!isCharging && _wasCharging) {
        _fireEvent(
          EventTriggerKind.chargingStop,
          triggerVars: _batteryTriggerVars(),
        );
      }

      if (state == BatteryState.full) {
        _fireEvent(
          EventTriggerKind.batteryFull,
          triggerVars: _batteryTriggerVars(levelOverride: 100),
        );
      }

      _wasCharging = isCharging;
    });

    // Periodically check battery level for threshold triggers.
    _batteryLevelTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _checkBatteryLevel(),
    );
    _checkBatteryLevel();
  }

  Future<void> _checkBatteryLevel() async {
    try {
      final level = await _battery.batteryLevel;
      if (_lastBatteryLevel > 0 && level < _lastBatteryLevel) {
        // Battery is draining — check thresholds.
        _fireEventWithParams(
          EventTriggerKind.batteryLow,
          (params) {
            final threshold = params?['threshold'] as int? ?? 20;
            return level <= threshold && _lastBatteryLevel > threshold;
          },
          triggerVars: _batteryTriggerVars(levelOverride: level),
        );
      }
      _lastBatteryLevel = level;
    } catch (_) {}
  }

  // ─── Connectivity Events ────────────────────────────────────────────────────

  void _listenConnectivity() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final connected = results.any((r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet);

      if (connected && !_wasConnected) {
        _fireEvent(EventTriggerKind.wifiConnected);
      } else if (!connected && _wasConnected) {
        _fireEvent(EventTriggerKind.wifiDisconnected);
      }

      _wasConnected = connected;
    });
  }

  // ─── Notification Events ────────────────────────────────────────────────────

  /// Subscribe to the notification stream from native. Each incoming
  /// notification is matched against keyword triggers via
  /// [_handleNotification].
  void _listenNotifications() {
    final service = _ref.read(notificationServiceProvider);
    _notificationSub = service.incoming.listen(_handleNotification);
  }

  /// Match an incoming notification against all keyword-based event
  /// workflows and fire any whose keyword(s) appear in title+body. The
  /// notification metadata is exposed to the workflow prompt as `{{notif}}`,
  /// `{{notif_title}}`, `{{notif_body}}`, `{{notif_app}}`, `{{notif_keyword}}`.
  Future<void> _handleNotification(NotificationInfo info) async {
    final title = info.title ?? '';
    final body = info.text ?? '';
    final text = '$title $body'.toLowerCase().trim();
    if (text.isEmpty) return;

    final workflows = await _repo.listEventTriggered();
    for (final wf in workflows) {
      if (wf.trigger.eventKind != EventTriggerKind.notificationKeyword) continue;
      final rawKeyword =
          (wf.trigger.eventParams?['keyword'] as String? ?? '').trim();
      if (rawKeyword.isEmpty) continue;
      // Comma-separated keyword list: ANY match fires the workflow.
      final keywords = rawKeyword
          .split(',')
          .map((k) => k.trim().toLowerCase())
          .where((k) => k.isNotEmpty)
          .toList();
      final matched = keywords.firstWhere(
        text.contains,
        orElse: () => '',
      );
      if (matched.isEmpty) continue;

      _triggerWorkflow(
        wf,
        triggerVars: _buildNotifTriggerVars(info, matched),
      );
    }
  }

  /// Test/manual hook so tests and other callers can drive the keyword logic
  /// without a real platform notification.
  Future<void> onNotificationReceived(String title, String body) async {
    await _handleNotification(NotificationInfo(
      id: 'manual-${DateTime.now().millisecondsSinceEpoch}',
      packageName: 'manual',
      appName: 'Manual',
      title: title,
      text: body,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      clearable: true,
    ));
  }

  Map<String, String> _buildNotifTriggerVars(
    NotificationInfo info,
    String matchedKeyword,
  ) {
    final title = info.title?.trim() ?? '';
    final body = info.text?.trim() ?? '';
    final combined = title.isEmpty
        ? body
        : (body.isEmpty ? title : '$title — $body');
    return {
      'notif': combined,
      'notif_title': title,
      'notif_body': body,
      'notif_app': info.appName,
      'notif_keyword': matchedKeyword,
    };
  }

  // ─── App Opened (called externally) ────────────────────────────────

  /// Called by DeviceContext when foreground app changes.
  Future<void> onAppOpened(String packageName) async {
    final workflows = await _repo.listEventTriggered();

    for (final wf in workflows) {
      if (wf.trigger.eventKind != EventTriggerKind.appOpened) continue;
      final targetPackage = wf.trigger.eventParams?['package'] as String? ?? '';
      if (targetPackage.isEmpty) continue;
      if (packageName.toLowerCase() == targetPackage.toLowerCase()) {
        _triggerWorkflow(
          wf,
          triggerVars: {
            'app_package': packageName,
          },
        );
      }
    }
  }

  // ─── Internal ───────────────────────────────────────────────────────────────

  /// Fire all workflows matching an event kind (no param check).
  Future<void> _fireEvent(
    EventTriggerKind kind, {
    Map<String, String>? triggerVars,
  }) async {
    final workflows = await _repo.listEventTriggered();
    for (final wf in workflows) {
      if (wf.trigger.eventKind == kind) {
        _triggerWorkflow(wf, triggerVars: triggerVars);
      }
    }
  }

  /// Fire workflows matching an event kind with param validation.
  Future<void> _fireEventWithParams(
    EventTriggerKind kind,
    bool Function(Map<String, dynamic>? params) paramCheck, {
    Map<String, String>? triggerVars,
  }) async {
    final workflows = await _repo.listEventTriggered();
    for (final wf in workflows) {
      if (wf.trigger.eventKind == kind &&
          paramCheck(wf.trigger.eventParams)) {
        _triggerWorkflow(wf, triggerVars: triggerVars);
      }
    }
  }

  Map<String, String> _batteryTriggerVars({int? levelOverride}) {
    final level = levelOverride ?? _lastBatteryLevel;
    if (level < 0) return const {};
    return {'battery_level': level.toString()};
  }

  /// Trigger a workflow with cooldown protection.
  void _triggerWorkflow(
    WorkflowModel wf, {
    Map<String, String>? triggerVars,
  }) {
    final now = DateTime.now();
    final lastFire = _lastFired[wf.id];
    if (lastFire != null && now.difference(lastFire) < _cooldown) {
      return; // Still in cooldown.
    }
    _lastFired[wf.id] = now;

    // Enqueue in the runner.
    final runner = _ref.read(workflowRunnerProvider);
    runner.enqueue(wf, triggerVars: triggerVars);
  }
}

/// Provider for the event listener.
final workflowEventListenerProvider = Provider<WorkflowEventListener>((ref) {
  return WorkflowEventListener(ref);
});

