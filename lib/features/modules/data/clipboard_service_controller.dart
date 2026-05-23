import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Controls native Android services for clipboard processing.
class ClipboardServiceController {
  static const _channel = MethodChannel('com.meowagent/services');

  // Persistent notification service.
  Future<bool> startNotificationService() async {
    try {
      return await _channel.invokeMethod<bool>('startNotificationService') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> stopNotificationService() async {
    try {
      return await _channel.invokeMethod<bool>('stopNotificationService') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> isNotificationServiceRunning() async {
    try {
      return await _channel.invokeMethod<bool>('isNotificationServiceRunning') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> requestNotificationPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestNotificationPermission') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  // Floating bubble service.
  Future<bool> startBubbleService() async {
    try {
      return await _channel.invokeMethod<bool>('startBubbleService') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> stopBubbleService() async {
    try {
      return await _channel.invokeMethod<bool>('stopBubbleService') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> isBubbleServiceRunning() async {
    try {
      return await _channel.invokeMethod<bool>('isBubbleServiceRunning') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Check if the app has SYSTEM_ALERT_WINDOW (overlay) permission.
  Future<bool> canDrawOverlays() async {
    try {
      return await _channel.invokeMethod<bool>('canDrawOverlays') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Open Android settings for the user to grant overlay permission.
  Future<bool> requestOverlayPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestOverlayPermission') ??
          false;
    } on PlatformException {
      return false;
    }
  }
}

final clipboardServiceControllerProvider =
    Provider<ClipboardServiceController>(
  (ref) => ClipboardServiceController(),
);
