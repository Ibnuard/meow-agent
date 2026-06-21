import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/runtime_memory.dart';

void main() {
  group('RuntimeMemory recency scoping', () {
    test('surfaces recent entries into prompts', () {
      final mem = RuntimeMemory();
      mem.record(
        agentId: 'a1',
        toolName: 'notes.create',
        args: const {'title': 'AI'},
        data: const {'id': 'note_1'},
        success: true,
      );

      final block = mem.formatForPrompt('a1');
      expect(block, contains('notes.create'));
      expect(block, contains('note_1'));
    });

    test('omits entries older than the relevance window', () {
      final mem = RuntimeMemory();
      mem.record(
        agentId: 'a1',
        toolName: 'notes.create',
        args: const {'title': 'AI'},
        data: const {'id': 'note_1'},
        success: true,
      );

      // Query as if the relevance window has fully elapsed: the stale entry
      // must not surface into the prompt (context-bleed guard).
      final future = DateTime.now().add(
        RuntimeMemory.promptRelevanceWindow + const Duration(minutes: 1),
      );
      expect(mem.formatForPrompt('a1', now: future), isEmpty);
    });

    test('mixes fresh and stale: only fresh surfaces', () {
      final mem = RuntimeMemory();
      // Record one entry "now" — it is fresh relative to a near-future query.
      mem.record(
        agentId: 'a1',
        toolName: 'agent.list',
        args: const {},
        data: const {'count': 3},
        success: true,
      );
      final soon = DateTime.now().add(const Duration(minutes: 1));
      final block = mem.formatForPrompt('a1', now: soon);
      expect(block, contains('agent.list'));
    });

    test('recent() still returns entries regardless of age', () {
      // Explicit lookups (e.g. "the note I created earlier") must still find
      // recorded entries — only PROMPT surfacing is recency-scoped.
      final mem = RuntimeMemory();
      mem.record(
        agentId: 'a1',
        toolName: 'notes.create',
        args: const {},
        data: const {'id': 'note_1'},
        success: true,
      );
      expect(mem.recent('a1'), hasLength(1));
    });
  });
}
