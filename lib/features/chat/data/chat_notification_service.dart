import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notification service for new chat replies.
///
/// Fires a system notification when an agent replies and the user is NOT
/// currently viewing that agent's chat screen. Works regardless of whether
/// the app itself is in the foreground, background, or terminated.
///
/// Tap on notification with payload "chat:agentId" navigates to the chat.
/// Confirmation notifications use payload "confirm:agentId" with action buttons.
class ChatNotificationService {
  ChatNotificationService._();

  static final ChatNotificationService instance = ChatNotificationService._();

  static const _channelIdBase = 'chat_reply';
  static const _channelName = 'Chat Replies';
  static const _channelDesc = 'Notifications for new agent replies';

  static const _confirmChannelId = 'chat_confirmation';
  static const _confirmChannelName = 'Agent Confirmations';
  static const _confirmChannelDesc =
      'Notifications requiring user confirmation for sensitive actions';

  // Action IDs for confirmation buttons.
  static const actionAccept = 'confirm_accept';
  static const actionAlways = 'confirm_always';
  static const actionReject = 'confirm_reject';

  /// The shared plugin instance — must be the SAME instance used by
  /// WorkflowNotificationService to avoid callback conflicts.
  /// Set via [attachPlugin] during app init.
  FlutterLocalNotificationsPlugin? _sharedPlugin;

  /// Fallback plugin for firing notifications if shared isn't attached yet.
  final FlutterLocalNotificationsPlugin _fallbackPlugin =
      FlutterLocalNotificationsPlugin();

  FlutterLocalNotificationsPlugin get _plugin => _sharedPlugin ?? _fallbackPlugin;

  /// Track which sound-specific channel has been created this session.
  final Set<String> _createdChannels = {};

  /// Attach the shared plugin instance (called from main.dart after
  /// WorkflowNotificationService.initialize). This ensures all notification
  /// services share one callback pipeline.
  void attachPlugin(FlutterLocalNotificationsPlugin plugin) {
    _sharedPlugin = plugin;
  }

  /// Ensure the confirmation channel exists.
  Future<void> ensureConfirmationChannel() async {
    if (_createdChannels.contains(_confirmChannelId)) return;
    _createdChannels.add(_confirmChannelId);
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _confirmChannelId,
          _confirmChannelName,
          description: _confirmChannelDesc,
          importance: Importance.high,
          playSound: true,
        ),
      );
    }
  }

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

  /// Show a confirmation notification with Accept / Always / Reject buttons.
  ///
  /// Button taps route through the shared plugin callback in main.dart.
  Future<void> showConfirmation({
    required String agentId,
    required String agentName,
    required String preview,
    String? soundFileName,
  }) async {
    await ensureConfirmationChannel();
    final id = (agentId.hashCode.abs() % 100000) + 50000;

    final androidDetails = AndroidNotificationDetails(
      _confirmChannelId,
      _confirmChannelName,
      channelDescription: _confirmChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
      playSound: true,
      sound: soundFileName != null
          ? RawResourceAndroidNotificationSound(soundFileName)
          : null,
      category: AndroidNotificationCategory.message,
      styleInformation: BigTextStyleInformation(preview),
      actions: const [
        AndroidNotificationAction(
          actionAccept,
          '✓ Accept',
          showsUserInterface: true,
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          actionAlways,
          '✓✓ Always',
          showsUserInterface: true,
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          actionReject,
          '✗ Reject',
          showsUserInterface: true,
          cancelNotification: true,
        ),
      ],
    );

    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      id,
      '🔐 $agentName',
      preview,
      details,
      payload: 'confirm:$agentId',
    );
  }

  /// Cancel the notification for a specific agent (when user opens the chat).
  Future<void> cancel(String agentId) async {
    final id = agentId.hashCode.abs() % 100000;
    await _plugin.cancel(id);
    // Also cancel any confirmation notification.
    await _plugin.cancel(id + 50000);
  }
}
