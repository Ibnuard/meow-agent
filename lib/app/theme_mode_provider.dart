import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/local_storage_service.dart';
import '../core/storage/meow_config_repository.dart';

/// Persists the user's theme mode preference (system / light / dark).
class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier(LocalStorageService storage, this._config)
    : super(_load(storage, _config));

  static const _key = 'meow.theme_mode';

  final MeowConfigRepository _config;

  static ThemeMode _load(
    LocalStorageService storage,
    MeowConfigRepository config,
  ) {
    final raw = config.readPref('theme') ?? storage.readString(_key);
    return switch (raw) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await _config.writePref('theme', mode.name);
  }
}

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((
  ref,
) {
  return ThemeModeNotifier(
    ref.watch(localStorageProvider),
    ref.watch(meowConfigRepositoryProvider),
  );
});
