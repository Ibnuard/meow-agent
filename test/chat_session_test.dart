import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:meow_agent/features/chat/data/chat_history_service.dart';
import 'package:meow_agent/features/chat/data/chat_session_service.dart';

/// Verifies the Phase 1 session/context-id wiring:
/// - ChatSessionService creates and switches sessions per agent.
/// - ChatHistoryService auto-tags writes via the resolver.
/// - loadLatest can scope to a session id.
/// - listSessions returns distinct sessions, newest first, with previews.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('ChatSessionService', () {
    test('lazily creates and persists a session per agent', () async {
      final prefs = await SharedPreferences.getInstance();
      final service = ChatSessionService(prefs);

      final id1 = service.currentSessionId('agent-a');
      final id2 = service.currentSessionId('agent-a');
      expect(id1, isNotEmpty);
      expect(id1, 's-1');
      expect(id2, equals(id1), reason: 'second read returns same id');

      final other = service.currentSessionId('agent-b');
      expect(other, 's-2');
      expect(other, isNot(equals(id1)), reason: 'per-agent isolation');
    });

    test('startNewSession returns a fresh id and updates current', () async {
      final prefs = await SharedPreferences.getInstance();
      final service = ChatSessionService(prefs);

      final initial = service.currentSessionId('agent-a');
      final fresh = await service.startNewSession('agent-a');

      expect(initial, 's-1');
      expect(fresh, 's-2');
      expect(fresh, isNot(equals(initial)));
      expect(service.currentSessionId('agent-a'), equals(fresh));
    });

    test('setCurrentSession switches to an arbitrary id', () async {
      final prefs = await SharedPreferences.getInstance();
      final service = ChatSessionService(prefs);

      await service.setCurrentSession('agent-a', 'ctx_external');
      expect(service.currentSessionId('agent-a'), 'ctx_external');
    });
  });

  group('ChatHistoryService session tagging', () {
    late ChatHistoryService history;
    late String currentSession;

    setUp(() async {
      // The shared meow_chat.db is opened by the service. Wipe any leftover
      // rows from previous tests so assertions are deterministic.
      currentSession = 'sess_initial';
      history = ChatHistoryService(sessionIdResolver: (_) => currentSession);
      await history.clearAll();
    });

    tearDown(() async {
      await history.close();
    });

    test('addMessage auto-tags with the resolver session id', () async {
      await history.addMessage(
        'a1',
        ChatMessage(role: 'user', content: 'hello'),
      );
      currentSession = 'sess_after_reset';
      await history.addMessage(
        'a1',
        ChatMessage(role: 'user', content: 'world'),
      );

      // UI view: every message regardless of session.
      final all = await history.loadLatest('a1');
      expect(all.map((m) => m.content), ['hello', 'world']);

      // Runtime view scoped to current session — only the second message.
      final scoped = await history.loadLatest(
        'a1',
        sessionId: 'sess_after_reset',
      );
      expect(scoped.map((m) => m.content), ['world']);
    });

    test(
      'explicit sessionId argument wins over resolver and message field',
      () async {
        await history.addMessage(
          'a1',
          ChatMessage(
            role: 'user',
            content: 'manual',
            sessionId: 'sess_message_field',
          ),
          sessionId: 'sess_explicit_arg',
        );

        final scoped = await history.loadLatest(
          'a1',
          sessionId: 'sess_explicit_arg',
        );
        expect(scoped, hasLength(1));
        expect(scoped.first.content, 'manual');
        expect(scoped.first.sessionId, 'sess_explicit_arg');
      },
    );

    test('listSessions groups distinct sessions, newest first', () async {
      currentSession = 'sess_A';
      await history.addMessage(
        'a1',
        ChatMessage(role: 'user', content: 'first user line'),
      );
      await history.addMessage(
        'a1',
        ChatMessage(role: 'assistant', content: 'reply A'),
      );

      currentSession = 'sess_B';
      await history.addMessage(
        'a1',
        ChatMessage(role: 'user', content: 'second user line'),
      );

      final sessions = await history.listSessions('a1');
      expect(sessions, hasLength(2));
      // Newest session first (sess_B was inserted later -> highest first_id).
      expect(sessions.first.sessionId, 'sess_B');
      expect(sessions.first.preview, 'second user line');
      expect(sessions.first.messageCount, 1);
      expect(sessions.last.sessionId, 'sess_A');
      expect(sessions.last.preview, 'first user line');
      expect(sessions.last.messageCount, 2);
    });

    test('clearSession removes only one session for reset semantics', () async {
      currentSession = 'sess_A';
      await history.addMessage(
        'a1',
        ChatMessage(role: 'user', content: 'current session'),
      );
      currentSession = 'sess_B';
      await history.addMessage(
        'a1',
        ChatMessage(role: 'user', content: 'other session'),
      );

      await history.clearSession('a1', 'sess_A');

      final current = await history.loadLatest('a1', sessionId: 'sess_A');
      final other = await history.loadLatest('a1', sessionId: 'sess_B');
      final all = await history.loadLatest('a1');

      expect(current, isEmpty);
      expect(other.map((m) => m.content), ['other session']);
      expect(all.map((m) => m.content), ['other session']);
    });
  });
}
