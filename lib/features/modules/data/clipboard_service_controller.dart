import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Controls native Android services for clipboard monitoring.
class ClipboardServiceController {
  static const _channel = MethodChannel('com.meowagent/services');

  /// Start the persistent notification foreground service.
  Future<bool> startNotificationService() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('startNotificationService');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Stop the persistent notification foreground service.
  Future<bool> stopNotificationService() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('stopNotificationService');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Check if the notification service is currently running.
  Future<bool> isNotificationServiceRunning() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('isNotificationServiceRunning');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Check if the accessibility service is enabled.
  Future<bool> isAccessibilityEnabled() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('isAccessibilityEnabled');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Request POST_NOTIFICATIONS permission (Android 13+).
  Future<bool> requestNotificationPermission() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('requestNotificationPermission');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Open Android accessibility settings for the user to enable the service.
  Future<bool> openAccessibilitySettings() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('openAccessibilitySettings');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }
}

final clipboardServiceControllerProvider =
    Provider<ClipboardServiceController>(
  (ref) => ClipboardServiceController(),
);
