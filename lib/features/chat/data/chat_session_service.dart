import 'dart:math';

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
  ChatSessionService(
    this._prefs, {
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random();

  final SharedPreferences _prefs;
  final DateTime Function() _clock;
  final Random _random;

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

  /// Session id format: `MEOW-YYYYMMDD-XXXX-N`.
  ///
  /// - `YYYYMMDD` is the local date the session was minted, so a quick glance
  ///   at the id tells the user roughly when it was started.
  /// - `XXXX` is four random digits, mostly to keep ids visually distinct
  ///   when several sessions land on the same day.
  /// - `N` is the persisted monotonic counter, kept so ids stay strictly
  ///   ordered across the whole app even across days/restarts.
  String _generate() {
    final next = (_prefs.getInt(_counterKey) ?? 0) + 1;
    _prefs.setInt(_counterKey, next);
    final now = _clock();
    final ymd =
        '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    final rand = _random.nextInt(10000).toString().padLeft(4, '0');
    return 'MEOW-$ymd-$rand-$next';
  }
}

final chatSessionServiceProvider = Provider<ChatSessionService>(
  (ref) => ChatSessionService(ref.watch(sharedPreferencesProvider)),
);
