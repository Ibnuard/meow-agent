import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/prompt_constants.dart';

void main() {
  group('Analyzer prompt guardrails', () {
    test('cross-domain ambiguity rule covers same-turn app context', () {
      final rule = PromptConstants.analyzeCrossDomainAmbiguityRule;

      expect(rule, contains('FIRST_ASK_USER'));
      expect(rule, contains('CURRENT message'));
      expect(rule, contains('same-turn'));
      expect(rule, contains('No notification.summarize'));
    });
  });
}
