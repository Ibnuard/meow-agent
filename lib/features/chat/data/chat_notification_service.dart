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

  static const _channelIdBase = 'chat_reply';
  static const _channelName = 'Chat Replies';
  static const _channelDesc = 'Notifications for new agent replies';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Track which sound-specific channel has been created this session.
  final Set<String> _createdChannels = {};

  /// Ensure the channel for the given sound exists. Android locks channel
  /// sound at creation time, so we use a unique channel ID per sound.
  void _ensureChannelForSound(String? soundFileName) {
    final channelId = _channelIdForSound(soundFileName);
    if (_createdChannels.contains(channelId)) return;
    _createdChannels.add(channelId);

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      androidPlugin.createNotificationChannel(
        AndroidNotificationChannel(
          channelId,
          _channelName,
          description: _channelDesc,
          importance: Importance.high,
          sound: soundFileName != null
              ? RawResourceAndroidNotificationSound(soundFileName)
              : null,
          playSound: true,
        ),
      );
    }
  }

  /// Channel ID includes the sound name so each sound gets its own channel.
  static String _channelIdForSound(String? soundFileName) =>
      soundFileName != null ? '${_channelIdBase}_$soundFileName' : _channelIdBase;

  /// Show a notification for a new agent reply.
  ///
  /// [agentId] hash used as notification ID so each agent has at most one
  /// active notification. [agentName] for title, [preview] for body.
  /// [soundFileName] maps to `res/raw/<name>.ogg`.
  Future<void> show({
    required String agentId,
    required String agentName,
    required String preview,
    String? soundFileName,
  }) async {
    _ensureChannelForSound(soundFileName);
    final channelId = _channelIdForSound(soundFileName);
    final id = agentId.hashCode.abs() % 100000;

    final androidDetails = AndroidNotificationDetails(
      channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
      playSound: true,
      sound: soundFileName != null
          ? RawResourceAndroidNotificationSound(soundFileName)
          : null,
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
