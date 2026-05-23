import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kDebugModeKey = 'llm_debug_mode';

/// Provider for LLM debugging mode toggle.
final llmDebugModeProvider =
    StateNotifierProvider<LlmDebugModeNotifier, bool>((ref) {
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
