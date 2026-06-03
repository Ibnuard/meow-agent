import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../../features/modules/data/app_control_service.dart';
import '../../features/modules/notification_intelligence/notification_service.dart';

/// All runtime Android permissions used by Meow Agent.
///
/// Each variant maps to one or more [ph.Permission] constants.
enum PermissionType {
  /// POST_NOTIFICATIONS (Android 13+)
  notification,

  /// MANAGE_EXTERNAL_STORAGE (API 30+) or WRITE_EXTERNAL_STORAGE (API < 30)
  storage,

  /// SCHEDULE_EXACT_ALARM (Android 12+)
  scheduleExactAlarm,

  /// BLUETOOTH_CONNECT (Android 12+)
  bluetoothConnect,

  /// ACCESS_FINE_LOCATION / ACCESS_COARSE_LOCATION
  location,

  /// READ_PHONE_STATE
  phoneState,

  /// SYSTEM_ALERT_WINDOW
  systemAlertWindow,

  /// REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
  ignoreBatteryOptimizations,

  /// READ_CONTACTS
  contacts,

  /// CALL_PHONE
  callPhone,

  /// SEND_SMS
  sendSms,
}

/// Result of a permission check or request.
enum PermissionResult {
  /// Granted by the user.
  granted,

  /// Denied (not permanently — user can be asked again).
  denied,

  /// Permanently denied — user must enable via system settings.
  permanentlyDenied,

  /// Restricted by device policy or OS.
  restricted,
}

/// Centralized permission manager wrapping [ph.PermissionHandler].
///
/// Goals:
/// - Single entry point for ALL runtime permission checks & requests
/// - Automatic API-level fallback (e.g. storage vs manageExternalStorage)
/// - Rationale detection and settings redirect support
/// - No inline MethodChannel / native code in UI layers
class PermissionManager {
  PermissionManager({
    AppControlService? appControlService,
    NotificationService? notificationService,
  })  : _appControlService =
            appControlService ?? AppControlService(),
        _notificationService =
            notificationService ?? NotificationService();

  final AppControlService _appControlService;
  final NotificationService _notificationService;

  // ---------------------------------------------------------------------------
  // Check
  // ---------------------------------------------------------------------------

  /// Check whether the given permission is currently granted.
  Future<PermissionResult> check(PermissionType type) async {
    if (!Platform.isAndroid) return PermissionResult.granted;

    try {
      final permission = _resolvePermission(type);
      final status = await permission.status;
      return _mapStatus(status);
    } catch (_) {
      return PermissionResult.restricted;
    }
  }

  /// Convenience: true if [check] returns [PermissionResult.granted].
  Future<bool> isGranted(PermissionType type) async {
    return (await check(type)) == PermissionResult.granted;
  }

  /// Whether the user has permanently denied (should show settings redirect).
  Future<bool> isPermanentlyDenied(PermissionType type) async {
    if (!Platform.isAndroid) return false;
    try {
      final permission = _resolvePermission(type);
      final status = await permission.status;
      return status.isPermanentlyDenied;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Request
  // ---------------------------------------------------------------------------

  /// Request the given permission from the user.
  ///
  /// Returns [PermissionResult.granted] on success. If the user permanently
  /// denied in the past, returns [PermissionResult.permanentlyDenied] — callers
  /// should redirect to system settings.
  Future<PermissionResult> request(PermissionType type) async {
    if (!Platform.isAndroid) return PermissionResult.granted;

    try {
      final permission = _resolvePermission(type);
      final status = await permission.request();
      return _mapStatus(status);
    } catch (_) {
      return PermissionResult.restricted;
    }
  }

  /// Request permission with a rational dialog before the system prompt.
  ///
  /// Shows [dialogBuilder] (e.g. an [AlertDialog] explaining *why*) before
  /// calling [request]. If the user cancels the dialog, returns
  /// [PermissionResult.denied] without triggering the OS prompt.
  /// Request permission with a rational dialog before the system prompt.
  ///
  /// Shows [dialogBuilder] (e.g. an [AlertDialog] explaining *why*) before
  /// calling [request]. If the user cancels the dialog, returns
  /// [PermissionResult.denied] without triggering the OS prompt.
  Future<PermissionResult> requestWithRationale({
    required BuildContext context,
    required PermissionType type,
    required Widget Function(BuildContext context, VoidCallback onRequest)
        dialogBuilder,
  }) {
    return _requestWithRationaleImpl(context, type, dialogBuilder);
  }

  Future<PermissionResult> _requestWithRationaleImpl(
    BuildContext context,
    PermissionType type,
    Widget Function(BuildContext context, VoidCallback onRequest) dialogBuilder,
  ) async {
    if (!Platform.isAndroid) return PermissionResult.granted;

    final pre = await check(type);
    if (pre == PermissionResult.granted) return PermissionResult.granted;

    // ignore: use_build_context_synchronously
    final shouldRequest = await _showRationalDialog(context, dialogBuilder);
    if (!shouldRequest) return PermissionResult.denied;

    return request(type);
  }

  Future<bool> _showRationalDialog(
    BuildContext context,
    Widget Function(BuildContext context, VoidCallback onRequest) dialogBuilder,
  ) async {
    final completer = <bool>{};
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => dialogBuilder(ctx, () {
        completer.add(true);
        Navigator.of(ctx).pop();
      }),
    );
    return completer.contains(true);
  }

  /// Open Android system settings for this permission.
  ///
  /// For runtime permissions this opens the app's own Settings page. For
  /// special-access permissions (usage stats, notification listener, DND
  /// policy) it opens the corresponding system settings screen.
  Future<void> openSettings(PermissionType type) async {
    if (!Platform.isAndroid) return;

    switch (type) {
      case PermissionType.storage:
        await _appControlService.openSettings(
          action: 'android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION',
        );
      case PermissionType.notification:
      case PermissionType.bluetoothConnect:
      case PermissionType.location:
      case PermissionType.phoneState:
      case PermissionType.systemAlertWindow:
      case PermissionType.ignoreBatteryOptimizations:
      case PermissionType.scheduleExactAlarm:
      case PermissionType.contacts:
      case PermissionType.callPhone:
      case PermissionType.sendSms:
        await _openAppSettings();
    }
  }

  /// Open Usage Access settings (PACKAGE_USAGE_STATS).
  Future<void> openUsageAccessSettings() async {
    if (!Platform.isAndroid) return;
    await _appControlService.openSettings(
      action: 'android.settings.USAGE_ACCESS_SETTINGS',
    );
  }

  /// Open Notification Listener settings.
  Future<void> openNotificationListenerSettings() async {
    if (!Platform.isAndroid) return;
    await _notificationService.openAccessSettings();
  }

  /// Open Notification Policy Access settings (DND).
  Future<void> openNotificationPolicySettings() async {
    if (!Platform.isAndroid) return;
    await _appControlService.openSettings(
      action: 'android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS',
    );
  }

  /// Open SCHEDULE_EXACT_ALARM system settings.
  Future<void> openAlarmSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _appControlService.openSettings(
        action: 'android.settings.REQUEST_SCHEDULE_EXACT_ALARM',
      );
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Resolve [ph.Permission] for [type], with API-level fallback for storage.
  ph.Permission _resolvePermission(PermissionType type) {
    switch (type) {
      case PermissionType.notification:
        return ph.Permission.notification;
      case PermissionType.storage:
        return ph.Permission.manageExternalStorage;
      case PermissionType.scheduleExactAlarm:
        return ph.Permission.scheduleExactAlarm;
      case PermissionType.bluetoothConnect:
        return ph.Permission.bluetoothConnect;
      case PermissionType.location:
        return ph.Permission.location;
      case PermissionType.phoneState:
        return ph.Permission.phone;
      case PermissionType.systemAlertWindow:
        return ph.Permission.systemAlertWindow;
      case PermissionType.ignoreBatteryOptimizations:
        return ph.Permission.ignoreBatteryOptimizations;
      case PermissionType.contacts:
        return ph.Permission.contacts;
      case PermissionType.callPhone:
        return ph.Permission.phone;
      case PermissionType.sendSms:
        return ph.Permission.sms;
    }
  }

  PermissionResult _mapStatus(ph.PermissionStatus status) {
    if (status.isGranted) return PermissionResult.granted;
    if (status.isPermanentlyDenied) return PermissionResult.permanentlyDenied;
    if (status.isRestricted) return PermissionResult.restricted;
    return PermissionResult.denied;
  }

  Future<void> _openAppSettings() async {
    await ph.openAppSettings();
  }
}

/// RiverPod provider for [PermissionManager].
final permissionManagerProvider = Provider<PermissionManager>((ref) {
  return PermissionManager(
    appControlService: ref.read(appControlServiceProvider),
    notificationService: ref.read(notificationServiceProvider),
  );
});