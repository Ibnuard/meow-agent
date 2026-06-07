import 'package:flutter/services.dart';

/// Utility service for managing Android battery optimization exclusion.
///
/// When Meow Agent is excluded from battery optimization, Android will not
/// aggressively kill the process, allowing scheduled workflows to fire
/// reliably even during Doze mode.
class BatteryOptimizationService {
  static const _channel = MethodChannel('com.meowagent/battery_optimization');

  /// Check if the app is currently excluded from battery optimization.
  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _channel.invokeMethod<bool>('isIgnoring') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Request the system to exclude this app from battery optimization.
  /// Shows the system dialog (ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).
  /// Returns true if the user granted the exclusion.
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      return await _channel.invokeMethod<bool>('requestIgnore') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Open the battery optimization settings page directly.
  /// Useful as fallback when the direct request is denied or unavailable.
  static Future<void> openBatterySettings() async {
    try {
      await _channel.invokeMethod<void>('openBatterySettings');
    } catch (_) {
      // Non-fatal — user can navigate manually.
    }
  }
}
