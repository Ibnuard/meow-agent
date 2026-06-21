import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kDebugModeKey = 'llm_debug_mode';
const _kShowHiddenSettingsKey = 'show_hidden_settings';
const _kMascotTapCountKey = 'mascot_tap_count';

/// Provider for LLM debugging mode toggle.
final llmDebugModeProvider = StateNotifierProvider<LlmDebugModeNotifier, bool>((
  ref,
) {
  return LlmDebugModeNotifier();
});

class LlmDebugModeNotifier extends StateNotifier<bool> {
  LlmDebugModeNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_kDebugModeKey) ?? false;
  }

  Future<void> toggle(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDebugModeKey, value);
  }
}

/// Provider for hidden settings reveal state (unlocked by tapping mascot 10x).
final hiddenSettingsRevealedProvider =
    StateNotifierProvider<HiddenSettingsRevealedNotifier, bool>((ref) {
      return HiddenSettingsRevealedNotifier();
    });

class HiddenSettingsRevealedNotifier extends StateNotifier<bool> {
  HiddenSettingsRevealedNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_kShowHiddenSettingsKey) ?? false;
  }

  Future<void> reveal() async {
    if (state) return;
    state = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowHiddenSettingsKey, true);
    await prefs.remove(_kMascotTapCountKey);
  }

  int get tapCount {
    // This is handled separately via SharedPreferences for cross-session persistence
    return 0;
  }
}
