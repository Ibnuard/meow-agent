import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notification_models.dart';

/// Flutter wrapper for the native NotificationListener bridge.
/// Read-only — never sends, dismisses, or replies.
class NotificationService {
  NotificationService._() {
    // One-time handler registration. Native MainActivity invokes
    // 'onNotificationPosted' on this channel for every new notification.
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;

  static const _channel = MethodChannel('com.meowagent/notifications');

  final StreamController<NotificationInfo> _incoming =
      StreamController<NotificationInfo>.broadcast();

  /// Broadcast stream of newly-posted notifications.
  /// Used by [WorkflowEventListener] to fire keyword triggers and any other
  /// real-time consumer (digesters, summarizers).
  Stream<NotificationInfo> get incoming => _incoming.stream;

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onNotificationPosted':
        final raw = call.arguments;
        if (raw is Map) {
          try {
            final info = NotificationInfo.fromMap(raw);
            if (info.hasContent) {
              _incoming.add(info);
            }
          } catch (_) {
            // Malformed payload — drop silently.
          }
        }
        return null;
      default:
        return null;
    }
  }

  Future<bool> isAccessGranted() async {
    try {
      final granted = await _channel.invokeMethod<bool>('isNotificationAccessGranted');
      return granted ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> openAccessSettings() async {
    try {
      await _channel.invokeMethod('openNotificationAccessSettings');
    } on PlatformException {
      // Best-effort: caller treats as no-op if unavailable.
    }
  }

  Future<List<NotificationInfo>> getRecent({int limit = 10}) async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'getRecentNotifications',
        {'limit': limit.clamp(1, 100)},
      );
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((m) => NotificationInfo.fromMap(m))
          .where((n) => n.hasContent)
          .toList();
    } on PlatformException {
      return const [];
    }
  }

  Future<NotificationInfo?> getById(String id) async {
    if (id.isEmpty) return null;
    try {
      final raw = await _channel.invokeMethod<Map>(
        'getNotificationById',
        {'id': id},
      );
      if (raw == null) return null;
      return NotificationInfo.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  /// Reply to a notification using Android's RemoteInput mechanism.
  /// Returns a map with { success: bool, error: String? }.
  /// Only works for notifications that have a reply action (messaging apps).
  Future<Map<String, dynamic>> replyToNotification({
    required String notifId,
    required String message,
  }) async {
    if (notifId.isEmpty || message.isEmpty) {
      return {'success': false, 'error': 'notifId and message are required'};
    }
    try {
      final result = await _channel.invokeMethod<Map>(
        'replyToNotification',
        {'id': notifId, 'message': message},
      );
      if (result == null) {
        return {'success': false, 'error': 'null_response'};
      }
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      return {'success': false, 'error': e.message ?? 'platform_error'};
    }
  }

  /// Check if a notification supports direct reply (has RemoteInput action).
  Future<bool> hasReplyAction(String notifId) async {
    if (notifId.isEmpty) return false;
    try {
      final result = await _channel.invokeMethod<bool>(
        'hasReplyAction',
        {'id': notifId},
      );
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }
}

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(),
);

