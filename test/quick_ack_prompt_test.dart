import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/prompt_constants.dart';

void main() {
  test('quick ack prompt is tiny and gates chat versus agentic', () {
    final messages = PromptConstants.quickAckMessages(
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
    expect(system, contains('"mode":"agentic|chat"'));
    expect(system, contains('"ack":"..."'));
    expect(system, contains('If mode is chat, ack MUST be empty'));
    expect(system, contains('Do not claim success'));
    expect(system, isNot(contains('Available tools')));
    expect(system, isNot(contains('Conversation history')));
  });
}
