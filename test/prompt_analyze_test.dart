import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/prompt_constants.dart';
import 'package:meow_agent/services/agent_runtime/prompt_templates.dart';
import 'package:meow_agent/services/agent_runtime/predefined_skills/predefined_skills.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';

void main() {
  group('Analyzer prompt guardrails', () {
    test(
      'cross-domain ambiguity rule guards built-in vs ambiguous routing',
      () {
        final rule = PromptConstants.analyzeCrossDomainAmbiguityRule;

        expect(rule, contains('FIRST_ASK_USER'));
        expect(rule, contains('CURRENT message'));
        expect(rule, contains('explicitly scopes'));
        expect(rule, contains('one interpretation dominates'));
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
        contains('Ask for scope when missing'),
      );
      expect(
        PromptConstants.analyzeResponseFormat,
        contains('"requested_item_count"'),
      );
      expect(
        PromptConstants.analyzeResponseFormat,
        contains('"selected_skill_ids"'),
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

    test(
      'failed actions remain unresolved until the same outcome succeeds',
      () {
        expect(
          PromptConstants.selectToolResponseFormat,
          contains('success=false is authoritative proof'),
        );
        expect(
          PromptConstants.reviewResponseFormat,
          contains('unresolved failure for the active'),
        );
        expect(
          PromptConstants.reviewResponseFormat,
          contains('Never mark a failed deletion done'),
        );
      },
    );

    test('analyzer has predefined skill selection instructions', () {
      final block = PromptConstants.analyzePredefinedSkillIndex(
        '- meow.app: Open apps. tool_groups=[app]; key_tools=[app.open]',
      );

      expect(block, contains('Predefined skill index'));
      expect(block, contains('selected_skill_ids'));
      expect(block, contains('Never invent a skill id'));
    });

    test('module-specific examples live in selected skill details', () {
      final index = PredefinedSkillRegistry.analyzerIndexBlock();
      expect(index, contains('db.create_table'));
      expect(index, contains('system.profile.update'));
      expect(index, contains('app.resolve'));
      expect(index, isNot(contains('"open <app>"')));

      final appDetail = PredefinedSkillRegistry.skillDetailBlock(['meow.app']);
      expect(appDetail, contains('"open <app>"'));
      expect(appDetail, contains('app.resolve then app.open'));
    });

    test('analyzer constants do not own world model or examples', () {
      expect(PromptConstants.systemMarkdownMap, contains('meow_core.db'));
      expect(
        PromptConstants.analyzeRequiresToolsRules,
        isNot(contains('meow_core.db')),
      );
      expect(PromptConstants.analyzeResponseFormat, contains('subgoal_seeds'));
      expect(
        PromptConstants.analyzeResponseFormat,
        isNot(contains('create 3')),
      );
    });

    test(
      'analyze prompt does not inject heavy world model or database schema',
      () {
        final prompt = PromptTemplates.analyzePrompt(
          userMessage: 'show my tables',
          workspace: const AgentWorkspace(soul: 'User: Test'),
          availableTools: const ['- db.list_tables: list tables'],
          languageCode: 'en',
        );

        expect(prompt, contains('Predefined skill index'));
        expect(prompt, isNot(contains('System Database (meow_core.db')));
        expect(prompt, isNot(contains('World model (files.* tools)')));
        expect(prompt, isNot(contains('agent_soul(agent_id')));
        expect(prompt, isNot(contains('Documents/MeowAgent/Agents')));
      },
    );
  });
}
