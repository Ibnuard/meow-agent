import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'permission_manager.dart';

/// Snapshot of all runtime permission states for use in UI.
class PermissionStates {
  const PermissionStates({
    this.notification = PermissionResult.denied,
    this.storage = PermissionResult.denied,
    this.scheduleExactAlarm = PermissionResult.denied,
    this.bluetoothConnect = PermissionResult.denied,
    this.location = PermissionResult.denied,
    this.phoneState = PermissionResult.denied,
    this.systemAlertWindow = PermissionResult.denied,
    this.ignoreBatteryOptimizations = PermissionResult.denied,
  });

  final PermissionResult notification;
  final PermissionResult storage;
  final PermissionResult scheduleExactAlarm;
  final PermissionResult bluetoothConnect;
  final PermissionResult location;
  final PermissionResult phoneState;
  final PermissionResult systemAlertWindow;
  final PermissionResult ignoreBatteryOptimizations;

  PermissionResult operator [](PermissionType type) => switch (type) {
    PermissionType.notification => notification,
    PermissionType.storage => storage,
    PermissionType.scheduleExactAlarm => scheduleExactAlarm,
    PermissionType.bluetoothConnect => bluetoothConnect,
    PermissionType.location => location,
    PermissionType.phoneState => phoneState,
    PermissionType.systemAlertWindow => systemAlertWindow,
    PermissionType.ignoreBatteryOptimizations => ignoreBatteryOptimizations,
  };

  PermissionStates _with(PermissionType type, PermissionResult result) {
    return switch (type) {
      PermissionType.notification => copyWith(notification: result),
      PermissionType.storage => copyWith(storage: result),
      PermissionType.scheduleExactAlarm => copyWith(scheduleExactAlarm: result),
      PermissionType.bluetoothConnect => copyWith(bluetoothConnect: result),
      PermissionType.location => copyWith(location: result),
      PermissionType.phoneState => copyWith(phoneState: result),
      PermissionType.systemAlertWindow => copyWith(systemAlertWindow: result),
      PermissionType.ignoreBatteryOptimizations =>
        copyWith(ignoreBatteryOptimizations: result),
    };
  }

  PermissionStates copyWith({
    PermissionResult? notification,
    PermissionResult? storage,
    PermissionResult? scheduleExactAlarm,
    PermissionResult? bluetoothConnect,
    PermissionResult? location,
    PermissionResult? phoneState,
    PermissionResult? systemAlertWindow,
    PermissionResult? ignoreBatteryOptimizations,
  }) {
    return PermissionStates(
      notification: notification ?? this.notification,
      storage: storage ?? this.storage,
      scheduleExactAlarm: scheduleExactAlarm ?? this.scheduleExactAlarm,
      bluetoothConnect: bluetoothConnect ?? this.bluetoothConnect,
      location: location ?? this.location,
      phoneState: phoneState ?? this.phoneState,
      systemAlertWindow: systemAlertWindow ?? this.systemAlertWindow,
      ignoreBatteryOptimizations:
          ignoreBatteryOptimizations ?? this.ignoreBatteryOptimizations,
    );
  }
}

/// Lifecycle-aware permission observer.
///
/// Listens to app lifecycle events and re-checks all permissions when the
/// app returns from background (e.g. user granted/revoked permission in
/// system settings). Exposes reactive state via [permissionStateProvider].
class PermissionObserver extends WidgetsBindingObserver {
  PermissionObserver(this._ref) {
    WidgetsBinding.instance.addObserver(this);
    _refreshAll();
  }

  final Ref _ref;

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshAll();
    }
  }

  Future<void> _refreshAll() async {
    final pm = _ref.read(permissionManagerProvider);
    var states = const PermissionStates();
    for (final type in PermissionType.values) {
      final result = await pm.check(type);
      states = states._with(type, result);
    }
    _ref.read(permissionStateProvider.notifier).setAll(states);
  }
}

/// Reactive RiverPod state for all permission states.
///
/// Updated automatically by [PermissionObserver] when the app resumes.
final permissionStateProvider =
    StateNotifierProvider<PermissionStateNotifier, PermissionStates>((ref) {
  return PermissionStateNotifier();
});

class PermissionStateNotifier extends StateNotifier<PermissionStates> {
  PermissionStateNotifier() : super(const PermissionStates());

  void update(PermissionType type, PermissionResult result) {
    state = state._with(type, result);
  }

  void setAll(PermissionStates states) {
    state = states;
  }
}

/// Provider that creates and manages the [PermissionObserver] lifecycle.
final permissionObserverProvider = Provider<PermissionObserver>((ref) {
  final observer = PermissionObserver(ref);
  ref.onDispose(observer.dispose);
  return observer;
});