/// Notification info from the read-only listener cache.
class NotificationInfo {
  const NotificationInfo({
    required this.id,
    required this.packageName,
    required this.appName,
    this.title,
    this.text,
    required this.timestamp,
    required this.clearable,
  });

  final String id;
  final String packageName;
  final String appName;
  final String? title;
  final String? text;
  final int timestamp;
  final bool clearable;

  Map<String, dynamic> toJson() => {
        'id': id,
        'packageName': packageName,
        'appName': appName,
        'title': title,
        'text': text,
        'timestamp': timestamp,
        'clearable': clearable,
      };

  factory NotificationInfo.fromMap(Map<dynamic, dynamic> m) => NotificationInfo(
        id: m['id'] as String? ?? '',
        packageName: m['packageName'] as String? ?? '',
        appName: m['appName'] as String? ?? 'Unknown',
        title: (m['title'] as String?)?.trim().isEmpty == true
            ? null
            : m['title'] as String?,
        text: (m['text'] as String?)?.trim().isEmpty == true
            ? null
            : m['text'] as String?,
        timestamp: (m['timestamp'] as num?)?.toInt() ?? 0,
        clearable: m['clearable'] as bool? ?? true,
      );

  /// True if the notification has any meaningful display content.
  bool get hasContent =>
      (title != null && title!.isNotEmpty) || (text != null && text!.isNotEmpty);
}

/// Result of an importance classification on a single notification.
class NotificationImportance {
  const NotificationImportance({
    required this.notification,
    required this.reason,
  });

  final NotificationInfo notification;
  final String reason;

  Map<String, dynamic> toJson() => {
        'id': notification.id,
        'appName': notification.appName,
        'title': notification.title,
        'reason': reason,
      };
}
