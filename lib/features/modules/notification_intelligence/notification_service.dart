import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notification_models.dart';

/// Flutter wrapper for the native NotificationListener bridge.
/// Read-only — never sends, dismisses, or replies.
class NotificationService {
  static const _channel = MethodChannel('com.meowagent/notifications');

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
}

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(),
);
