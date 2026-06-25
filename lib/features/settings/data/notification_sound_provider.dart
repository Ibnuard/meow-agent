import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/local_storage_service.dart';

/// Available notification sounds (mapped to res/raw/*.ogg files).
enum NotificationSound {
  notification('notification', 'Default'),
  cat('cat', 'Meow');

  const NotificationSound(this.fileName, this.label);

  /// File name without extension — matches `res/raw/<fileName>.ogg`.
  final String fileName;

  /// Display label (used in UI).
  final String label;
}

const notificationSoundPreferenceKey = 'notification_sound';

/// Riverpod provider for the selected notification sound.
final notificationSoundProvider =
    StateNotifierProvider<NotificationSoundNotifier, NotificationSound>((ref) {
  return NotificationSoundNotifier(ref.watch(localStorageProvider));
});

class NotificationSoundNotifier extends StateNotifier<NotificationSound> {
  NotificationSoundNotifier(this._storage) : super(NotificationSound.notification) {
    _load();
  }

  final LocalStorageService _storage;

  void _load() {
    final stored = _storage.readString(notificationSoundPreferenceKey);
    if (stored != null) {
      final match = NotificationSound.values
          .where((s) => s.fileName == stored)
          .firstOrNull;
      if (match != null) state = match;
    }
  }

  Future<void> set(NotificationSound sound) async {
    state = sound;
    await _storage.writeString(notificationSoundPreferenceKey, sound.fileName);
  }
}

/// Helper to get the raw resource sound name for AndroidNotificationDetails.
String getNotificationSoundRawResource(NotificationSound sound) =>
    sound.fileName;
