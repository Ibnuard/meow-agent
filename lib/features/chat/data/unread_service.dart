import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks unread message counts per agent.
///
/// Singleton-backed so background services (workflow runner, chat.send tool)
/// can call [increment] without depending on a Riverpod scope. UI watches the
/// Riverpod provider for rebuilds.
///
/// Behavior:
/// - When an agent's chat screen is in the foreground (registered via
///   [setActive]), incoming messages do not bump the counter and any existing
///   count is cleared.
/// - Counts persist across app restarts via SharedPreferences.
class UnreadService extends ChangeNotifier {
  UnreadService._();

  static final UnreadService instance = UnreadService._();

  static const _prefKey = 'chat_unread_counts_v1';

  Map<String, int> _counts = {};
  String? _activeAgentId;
  bool _initialized = false;

  /// Hydrate from SharedPreferences. Idempotent.
  Future<void> ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _counts = decoded.map((k, v) => MapEntry(k, (v as num).toInt()))
          ..removeWhere((_, v) => v <= 0);
      }
    } catch (_) {
      // Corrupt prefs — start fresh.
      _counts = {};
    }
    notifyListeners();
  }

  /// Unread count for a specific agent.
  int countFor(String agentId) => _counts[agentId] ?? 0;

  /// Sum of unread counts across every agent.
  int get total => _counts.values.fold(0, (a, b) => a + b);

  /// True when any agent has unread messages.
  bool get hasAny => total > 0;

  /// Mark an agent's chat as in-foreground. Subsequent [increment] calls for
  /// that agent are no-ops, and any existing count is cleared so the badge
  /// disappears immediately when the user opens the chat.
  Future<void> setActive(String agentId) async {
    await ensureInit();
    _activeAgentId = agentId;
    if (_counts.remove(agentId) != null) {
      await _persist();
    }
    notifyListeners();
  }

  /// Clear active flag — call when leaving the chat screen.
  void clearActive(String agentId) {
    if (_activeAgentId == agentId) {
      _activeAgentId = null;
      // No notify — count is already correct, just toggling foreground state.
    }
  }

  /// Whether [agentId] is currently the active (in-foreground) chat.
  bool isActive(String agentId) => _activeAgentId == agentId;

  /// Increment unread for [agentId]. Skipped silently when the agent's chat
  /// is currently in the foreground.
  Future<void> increment(String agentId) async {
    await ensureInit();
    if (agentId.isEmpty) return;
    if (_activeAgentId == agentId) return;
    _counts[agentId] = (_counts[agentId] ?? 0) + 1;
    await _persist();
    notifyListeners();
  }

  /// Reset unread for an agent (e.g. user explicitly opens the chat).
  Future<void> markRead(String agentId) async {
    await ensureInit();
    if (_counts.remove(agentId) != null) {
      await _persist();
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(_counts));
    } catch (_) {
      // Best-effort persistence.
    }
  }
}

/// Riverpod provider that exposes the singleton for UI watch/listen.
final unreadServiceProvider = ChangeNotifierProvider<UnreadService>((ref) {
  final s = UnreadService.instance;
  // Fire-and-forget hydrate; first read returns empty until init resolves.
  s.ensureInit();
  return s;
});
