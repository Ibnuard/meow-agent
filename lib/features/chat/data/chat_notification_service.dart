import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notification service for new chat replies.
///
/// Fires a system notification when an agent replies and the user is NOT
/// currently viewing that agent's chat screen. Works regardless of whether
/// the app itself is in the foreground, background, or terminated.
///
/// Tap on notification with payload "chat:agentId" navigates to the chat.
class ChatNotificationService {
  ChatNotificationService._();

  static final ChatNotificationService instance = ChatNotificationService._();

  static const _channelId = 'chat_reply';
  static const _channelName = 'Chat Replies';
  static const _channelDesc = 'Notifications for new agent replies';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Initialize the Android notification channel. Call once at app startup
  /// AFTER the main [FlutterLocalNotificationsPlugin.initialize()] has run.
  void ensureChannel() {
    if (_initialized) return;
    _initialized = true;
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDesc,
          importance: Importance.high,
        ),
      );
    }
  }

  /// Show a notification for a new agent reply.
  ///
  /// [agentId] hash used as notification ID so each agent has at most one
  /// active notification. [agentName] for title, [preview] for body.
  Future<void> show({
    required String agentId,
    required String agentName,
    required String preview,
  }) async {
    ensureChannel();
    final id = agentId.hashCode.abs() % 100000;

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
      category: AndroidNotificationCategory.message,
      styleInformation: BigTextStyleInformation(preview),
    );

    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      id,
      agentName,
      preview,
      details,
      payload: 'chat:$agentId',
    );
  }

  /// Cancel the notification for a specific agent (when user opens the chat).
  Future<void> cancel(String agentId) async {
    final id = agentId.hashCode.abs() % 100000;
    await _plugin.cancel(id);
  }
}
