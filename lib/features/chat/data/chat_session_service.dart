import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/local_storage_service.dart';

/// Tracks the active chat "session" (a.k.a. context id) per agent.
///
/// A session is the unit of LLM context isolation. The chat UI keeps showing
/// every message across sessions, but the runtime only feeds the messages that
/// belong to the CURRENT session into the model. `/new-session` and `/clear`
/// create a new id; `/reset` keeps the id but clears persisted data for it;
/// `/resume` points the agent back at an existing id.
///
/// Backed by SharedPreferences (one key per agent). Reads are synchronous once
/// SharedPreferences is resolved, so callers can fetch the current id inline.
class ChatSessionService {
  ChatSessionService(this._prefs);

  final SharedPreferences _prefs;

  static String _key(String agentId) => 'chat_session_$agentId';
  static const String _counterKey = 'chat_session_counter_v2';

  /// Current session id for an agent. Lazily creates one on first access so
  /// existing installs transparently get a session without a migration step.
  String currentSessionId(String agentId) {
    final existing = _prefs.getString(_key(agentId));
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = _generate();
    // Fire-and-forget persist; the value is returned immediately so the first
    // message of a brand-new agent still lands in a stable session.
    _prefs.setString(_key(agentId), fresh);
    return fresh;
  }

  /// Begin a fresh session for an agent and return its id.
  Future<String> startNewSession(String agentId) async {
    final id = _generate();
    await _prefs.setString(_key(agentId), id);
    return id;
  }

  /// Point the agent at an existing session id (used by `/resume`).
  Future<void> setCurrentSession(String agentId, String sessionId) async {
    await _prefs.setString(_key(agentId), sessionId);
  }

  /// Short, copy-pasteable session id. A persisted counter keeps ids stable
  /// across app restarts without exposing timestamp/hash internals to users.
  String _generate() {
    final next = (_prefs.getInt(_counterKey) ?? 0) + 1;
    _prefs.setInt(_counterKey, next);
    return 's-$next';
  }
}

final chatSessionServiceProvider = Provider<ChatSessionService>(
  (ref) => ChatSessionService(ref.watch(sharedPreferencesProvider)),
);
