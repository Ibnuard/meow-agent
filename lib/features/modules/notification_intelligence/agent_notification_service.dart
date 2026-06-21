import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../settings/data/notification_sound_provider.dart';

/// Agent-initiated local notifications.
///
/// Lets agents push reminders, digests, and ad-hoc alerts to the user
/// outside of workflow execution. Channels are separate from workflow
/// channels so users can mute one without losing the other.
class AgentNotificationService {
  AgentNotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static const _channelSilent = 'agent_silent';
  static const _channelNormal = 'agent_normal';
  static const _channelAlarm = 'agent_alarm';

  static Future<void> _ensureInit() async {
    if (_initialized) return;
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    final settings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(settings);
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.requestNotificationsPermission();
    }
    _initialized = true;
  }

  /// Show a notification right now. Returns the notification id used.
  static Future<int> showNow({
    required String title,
    required String body,
    String style = 'normal',
    String? payload,
    String? soundFileName,
  }) async {
    await _ensureInit();
    final selectedSound = soundFileName ?? await _selectedSoundFileName();
    final id = DateTime.now().millisecondsSinceEpoch.remainder(2147483647);
    await _plugin.show(
      id,
      title,
      body,
      _detailsFor(style, selectedSound),
      payload: payload,
    );
    return id;
  }

  static Future<String> _selectedSoundFileName() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(notificationSoundPreferenceKey);
    if (stored != null && stored.isNotEmpty) return stored;
    return NotificationSound.notification.fileName;
  }

  static NotificationDetails _detailsFor(String style, String soundFileName) {
    final useSound = style != 'silent';
    final baseChannelId = switch (style) {
      'silent' => _channelSilent,
      'alarm' => _channelAlarm,
      _ => _channelNormal,
    };
    final channelId = useSound ? '${baseChannelId}_$soundFileName' : baseChannelId;
    final channelName = switch (style) {
      'silent' => 'Agent (Silent)',
      'alarm' => 'Agent (Alarm)',
      _ => 'Agent',
    };
    final importance = switch (style) {
      'silent' => Importance.low,
      'alarm' => Importance.max,
      _ => Importance.high,
    };
    final priority = switch (style) {
      'silent' => Priority.low,
      'alarm' => Priority.max,
      _ => Priority.high,
    };
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: 'Meow Agent push notifications ($style)',
        importance: importance,
        priority: priority,
        playSound: useSound,
        sound: useSound ? RawResourceAndroidNotificationSound(soundFileName) : null,
        enableVibration: style != 'silent',
        fullScreenIntent: style == 'alarm',
        autoCancel: true,
        category: style == 'alarm'
            ? AndroidNotificationCategory.alarm
            : AndroidNotificationCategory.reminder,
        vibrationPattern: style == 'alarm'
            ? Int64List.fromList([0, 500, 200, 500, 200, 500, 200, 1000])
            : null,
        enableLights: style == 'alarm',
        ledColor: const Color(0xFF3B82F6),
        ledOnMs: 1000,
        ledOffMs: 500,
      ),
    );
  }
}
