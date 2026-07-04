import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/prompt_constants.dart';

void main() {
  test('quick route prompt is tiny and gates chat versus agentic', () {
    final messages = PromptConstants.quickRouteMessages(
      agentName: 'Bejo',
      languageCode: 'id',
      userMessage: 'buatkan catatan x dan y',
    );

    expect(messages, hasLength(2));
    expect(messages.first['role'], 'system');
    expect(messages.last, {
      'role': 'user',
      'content': 'buatkan catatan x dan y',
    });

    final system = messages.first['content']!;
    expect(system, contains('"mode":"chat|agentic"'));
    expect(system, contains('"ack":"..."'));
    expect(system, contains('"direct_response":"..."'));
    expect(system, contains('If mode is chat'));
    expect(system, contains('direct_response is the complete answer'));
    expect(system, contains('If mode is agentic'));
    expect(system, contains('Do not claim success'));
    expect(system, isNot(contains('Available tools')));
    expect(system, isNot(contains('Conversation history')));
    expect(system, isNot(contains('worldModel')));
    expect(system, isNot(contains('stableContext')));
  });
}
