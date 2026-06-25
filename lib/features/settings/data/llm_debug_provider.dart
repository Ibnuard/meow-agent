import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/local_storage_service.dart';

const _kDebugModeKey = 'llm_debug_mode';
const _kShowHiddenSettingsKey = 'show_hidden_settings';
const _kMascotTapCountKey = 'mascot_tap_count';

/// Provider for LLM debugging mode toggle.
final llmDebugModeProvider = StateNotifierProvider<LlmDebugModeNotifier, bool>((
  ref,
) {
  return LlmDebugModeNotifier(ref.watch(localStorageProvider));
});

class LlmDebugModeNotifier extends StateNotifier<bool> {
  LlmDebugModeNotifier(this._storage) : super(false) {
    _load();
  }

  final LocalStorageService _storage;

  void _load() {
    state = _storage.readBool(_kDebugModeKey) ?? false;
  }

  Future<void> toggle(bool value) async {
    state = value;
    await _storage.writeBool(_kDebugModeKey, value);
  }
}

/// Provider for hidden settings reveal state (unlocked by tapping mascot 10x).
final hiddenSettingsRevealedProvider =
    StateNotifierProvider<HiddenSettingsRevealedNotifier, bool>((ref) {
      return HiddenSettingsRevealedNotifier(ref.watch(localStorageProvider));
    });

class HiddenSettingsRevealedNotifier extends StateNotifier<bool> {
  HiddenSettingsRevealedNotifier(this._storage) : super(false) {
    _load();
  }

  final LocalStorageService _storage;

  void _load() {
    state = _storage.readBool(_kShowHiddenSettingsKey) ?? false;
  }

  Future<void> reveal() async {
    if (state) return;
    state = true;
    await _storage.writeBool(_kShowHiddenSettingsKey, true);
    await _storage.remove(_kMascotTapCountKey);
  }

  int get tapCount {
    return 0;
  }
}
