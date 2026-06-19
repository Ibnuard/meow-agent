import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/features/chat/data/chat_runtime_manager.dart';
import 'package:meow_agent/features/chat/data/chat_history_service.dart';

void main() {
  test('pre-action narrator replaces the previous phase', () {
    final planning = ChatRuntimeSession(
      agentId: 'agent-1',
    ).copyWith(narrativeMessage: 'Planning next.');
    final reviewing = planning.copyWith(narrativeMessage: 'Reviewing next.');

    expect(reviewing.narrativeTrail, ['Reviewing next.']);
    expect(reviewing.narrativeMessage, 'Reviewing next.');
  });

  test('live semantic checkpoints accumulate and can be cleared', () {
    final first = ChatMessage(role: 'assistant', content: 'First done.');
    final second = ChatMessage(role: 'assistant', content: 'Next action.');
    final active = ChatRuntimeSession(
      agentId: 'agent-1',
    ).copyWith(liveCheckpoints: [first, second]);

    expect(active.liveCheckpoints.map((message) => message.content), [
      'First done.',
      'Next action.',
    ]);
    expect(
      active.copyWith(clearLiveCheckpoints: true).liveCheckpoints,
      isEmpty,
    );
  });
}
