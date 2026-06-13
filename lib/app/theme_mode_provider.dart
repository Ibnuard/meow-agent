import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_settings_repository.dart';

/// Storage key for theme mode in app_settings table.
const _themeKey = 'prefs.theme';

/// Initial theme mode loaded once at app boot in main() and injected into
/// the [ProviderScope]. Lets [ThemeModeNotifier] start synchronously without
/// blocking the first frame on a SQLite read.
final initialThemeModeProvider = Provider<String>((_) => 'system');

/// Persists the user's theme mode preference (system / light / dark).
///
/// Subscribes to [AppSettingsRepository.watchAll] so writes from any path
/// (LLM tools via `system.config.patch /prefs/theme`, background tasks)
/// reach the UI immediately.
class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier(this._settings, String initial) : super(_parse(initial)) {
    _sub = _settings.watchAll().listen((map) {
      final fresh = _parse(map[_themeKey]);
      if (mounted && fresh != state) state = fresh;
    });
  }

  final AppSettingsRepository _settings;
  StreamSubscription<Map<String, String>>? _sub;

  static ThemeMode _parse(String? raw) => switch (raw) {
    'dark' => ThemeMode.dark,
    'light' => ThemeMode.light,
    _ => ThemeMode.system,
  };

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await _settings.set(_themeKey, mode.name);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((
  ref,
) {
  return ThemeModeNotifier(
    ref.watch(appSettingsRepositoryProvider),
    ref.watch(initialThemeModeProvider),
  );
});
