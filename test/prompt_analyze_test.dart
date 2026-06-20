import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/prompt_constants.dart';

void main() {
  group('Analyzer prompt guardrails', () {
    test(
      'cross-domain ambiguity rule guards built-in vs ambiguous routing',
      () {
        final rule = PromptConstants.analyzeCrossDomainAmbiguityRule;

        expect(rule, contains('FIRST_ASK_USER'));
        expect(rule, contains('CURRENT message'));
        expect(rule, contains('clearly the notification tool'));
        expect(rule, contains('clearly the clipboard tool'));
      },
    );

    test('LLM phases request a separate forward-looking narrator field', () {
      expect(
        PromptConstants.nextNarrativeFieldRule,
        contains('future-looking'),
      );
      expect(
        PromptConstants.analyzeResponseFormat,
        contains('"next_narrative"'),
      );
      expect(
        PromptConstants.reflectResponseFormat,
        contains('"next_narrative"'),
      );
      expect(PromptConstants.planResponseFormat, contains('"next_narrative"'));
      expect(
        PromptConstants.reviewResponseFormat,
        contains('"next_narrative"'),
      );
    });

    test('collection population requires scope and per-item completion', () {
      expect(PromptConstants.policyAsk, contains('POPULATING COLLECTIONS'));
      expect(
        PromptConstants.analyzeRequiresToolsRules,
        contains('Do not insert a sample row first'),
      );
      expect(
        PromptConstants.analyzeResponseFormat,
        contains('"requested_item_count"'),
      );
      expect(
        PromptConstants.planResponseFormat,
        contains('ONE subgoal per row'),
      );
      expect(
        PromptConstants.reviewResponseFormat,
        contains('NEVER satisfied by one representative'),
      );
    });

    test('task recap may proactively offer to populate an empty structure', () {
      final prompt = PromptConstants.taskSummaryPrompt(
        mainGoal: 'Create a table',
        subgoalsBlock: '- [done] create table',
        languageLabel: 'English',
        languageCode: 'en',
      );
      expect(prompt, contains('PROACTIVE EMPTY-STRUCTURE FOLLOW-UP'));
      expect(prompt, contains('offering to populate it'));
    });
  });
}
