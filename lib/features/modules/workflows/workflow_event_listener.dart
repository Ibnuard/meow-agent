import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  }

  /// Stop all listeners.
  void stop() {
    _batteryStateSub?.cancel();
    _connectivitySub?.cancel();
    _batteryLevelTimer?.cancel();
    _batteryStateSub = null;
    _connectivitySub = null;
    _batteryLevelTimer = null;
  }

  // ─── Battery Events ─────────────────────────────────────────────────────────

  void _listenBattery() {
    // Monitor charging state changes.
    _batteryStateSub = _battery.onBatteryStateChanged.listen((state) {
      final isCharging = state == BatteryState.charging ||
          state == BatteryState.full;

      if (isCharging && !_wasCharging) {
        _fireEvent(EventTriggerKind.chargingStart);
      } else if (!isCharging && _wasCharging) {
        _fireEvent(EventTriggerKind.chargingStop);
      }

      if (state == BatteryState.full) {
        _fireEvent(EventTriggerKind.batteryFull);
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

  // ─── Notification Keyword (called externally) ───────────────────────────────

  /// Called by NotificationIntelligence when a notification is received.
  /// Checks if any event workflow matches the keyword.
  Future<void> onNotificationReceived(String title, String body) async {
    final workflows = await _repo.listEventTriggered();
    final text = '$title $body'.toLowerCase();

    for (final wf in workflows) {
      if (wf.trigger.eventKind != EventTriggerKind.notificationKeyword) continue;
      final keyword = (wf.trigger.eventParams?['keyword'] as String? ?? '').toLowerCase();
      if (keyword.isEmpty) continue;
      if (text.contains(keyword)) {
        _triggerWorkflow(wf);
      }
    }
  }

  // ─── App Opened (called externally) ─────────────────────────────────────────

  /// Called by DeviceContext when foreground app changes.
  Future<void> onAppOpened(String packageName) async {
    final workflows = await _repo.listEventTriggered();

    for (final wf in workflows) {
      if (wf.trigger.eventKind != EventTriggerKind.appOpened) continue;
      final targetPackage = wf.trigger.eventParams?['package'] as String? ?? '';
      if (targetPackage.isEmpty) continue;
      if (packageName.toLowerCase() == targetPackage.toLowerCase()) {
        _triggerWorkflow(wf);
      }
    }
  }

  // ─── Internal ───────────────────────────────────────────────────────────────

  /// Fire all workflows matching an event kind (no param check).
  Future<void> _fireEvent(EventTriggerKind kind) async {
    final workflows = await _repo.listEventTriggered();
    for (final wf in workflows) {
      if (wf.trigger.eventKind == kind) {
        _triggerWorkflow(wf);
      }
    }
  }

  /// Fire workflows matching an event kind with param validation.
  Future<void> _fireEventWithParams(
    EventTriggerKind kind,
    bool Function(Map<String, dynamic>? params) paramCheck,
  ) async {
    final workflows = await _repo.listEventTriggered();
    for (final wf in workflows) {
      if (wf.trigger.eventKind == kind &&
          paramCheck(wf.trigger.eventParams)) {
        _triggerWorkflow(wf);
      }
    }
  }

  /// Trigger a workflow with cooldown protection.
  void _triggerWorkflow(WorkflowModel wf) {
    final now = DateTime.now();
    final lastFire = _lastFired[wf.id];
    if (lastFire != null && now.difference(lastFire) < _cooldown) {
      return; // Still in cooldown.
    }
    _lastFired[wf.id] = now;

    // Enqueue in the runner.
    final runner = _ref.read(workflowRunnerProvider);
    runner.enqueue(wf);
  }
}

/// Provider for the event listener.
final workflowEventListenerProvider = Provider<WorkflowEventListener>((ref) {
  return WorkflowEventListener(ref);
});
