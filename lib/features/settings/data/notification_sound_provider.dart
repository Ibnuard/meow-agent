import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Available notification sounds (mapped to res/raw/*.ogg files).
enum NotificationSound {
  notification('notification', 'Notification'),
  cat('cat', 'Cat');

  const NotificationSound(this.fileName, this.label);

  /// File name without extension — matches `res/raw/<fileName>.ogg`.
  final String fileName;

  /// Display label (used in UI).
  final String label;
}

const _prefKey = 'notification_sound';

/// Riverpod provider for the selected notification sound.
final notificationSoundProvider =
    StateNotifierProvider<NotificationSoundNotifier, NotificationSound>((ref) {
  return NotificationSoundNotifier();
});

class NotificationSoundNotifier extends StateNotifier<NotificationSound> {
  NotificationSoundNotifier() : super(NotificationSound.notification) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefKey);
    if (stored != null) {
      final match = NotificationSound.values
          .where((s) => s.fileName == stored)
          .firstOrNull;
      if (match != null) state = match;
    }
  }

  Future<void> set(NotificationSound sound) async {
    state = sound;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, sound.fileName);
  }
}

/// Helper to get the raw resource sound name for AndroidNotificationDetails.
String getNotificationSoundRawResource(NotificationSound sound) =>
    sound.fileName;
