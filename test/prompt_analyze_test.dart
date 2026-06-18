import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/prompt_constants.dart';

void main() {
  group('Analyzer prompt guardrails', () {
    test('cross-domain ambiguity rule guards built-in vs ambiguous routing',
        () {
      final rule = PromptConstants.analyzeCrossDomainAmbiguityRule;

      expect(rule, contains('FIRST_ASK_USER'));
      expect(rule, contains('CURRENT message'));
      expect(rule, contains('clearly the notification tool'));
      expect(rule, contains('clearly the clipboard tool'));
    });
  });
}
