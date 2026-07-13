import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/classifier.dart';
import 'package:meow_agent/services/agent_runtime/ecosystem_snapshot.dart';
import 'package:meow_agent/services/agent_runtime/language_detector.dart';
import 'package:meow_agent/services/agent_runtime/prompt_classify.dart';
import 'package:meow_agent/services/agent_runtime/prompt_constants.dart';
import 'package:meow_agent/services/agent_runtime/predefined_skills/predefined_skills.dart';
import 'package:meow_agent/services/agent_runtime/prompt_templates.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';

void main() {
  group('Classifier prompt guardrails', () {
    test(
      'cross-domain ambiguity rule guards built-in vs ambiguous routing',
      () {
        final rule = promptClassifyAnalyzeRules;

        expect(rule, contains('FIRST_ASK_USER'));
        expect(rule, contains('current user message'));
        expect(rule, contains('user/device scoped'));
        expect(rule, contains('one interpretation dominates'));
      },
    );

    test('classify response requests a forward-looking narrator field', () {
      expect(
        PromptConstants.nextNarrativeFieldRule,
        contains('future-looking'),
      );
      expect(
        promptClassifyResponseFormat,
        contains('"next_narrative"'),
      );
      expect(
        PromptConstants.reviewResponseFormat,
        contains('"next_narrative"'),
      );
    });

    test('collection population requires scope and per-item completion', () {
      expect(PromptConstants.policyAsk, contains('POPULATING COLLECTIONS'));
      expect(
        promptClassifyAnalyzeRules,
        contains('Ask for scope when missing'),
      );
      expect(
        promptClassifyResponseFormat,
        contains('"requested_item_count"'),
      );
      expect(
        promptClassifyResponseFormat,
        contains('"selected_skill_ids"'),
      );
      expect(
        promptClassifyPlanRules,
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
          contains('Never mark a failed deletion'),
        );
      },
    );

    test('classifier has predefined skill selection instructions', () {
      final block = PredefinedSkillRegistry.analyzerIndexBlock();

      expect(block, isNotEmpty);
      expect(block, contains('meow.app'));
      expect(promptClassifyAnalyzeRules, contains('predefined skill index'));
      expect(promptClassifyResponseFormat, contains('selected_skill_ids'));
    });

    test('profile persistence rules are injected into classify prompt', () {
      expect(
        PromptConstants.profilePersistenceRules,
        contains('system.profile.update'),
      );

      final prompt = Classifier.buildPrompt(
        userMessage: 'my name is Wowo',
        workspace: const AgentWorkspace(soul: '# Soul\nName: [Your Name]'),
        snapshot: EcosystemSnapshot(
          agents: const [],
          workflows: const [],
          providers: const [],
          modules: const [],
          builtAt: DateTime(2026, 1, 1),
        ),
        availableTools: const [],
        language: DetectedLanguage.fromAnalyzerCode('en'),
        recentMessages: const [
          {'role': 'assistant', 'content': 'What name should I use?'},
        ],
      );

      expect(prompt, contains('PROFILE PERSISTENCE RULES'));
      expect(prompt, contains('full agentic runtime'));
      expect(prompt, contains('system.profile.update'));
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

    test('classify constants do not own world model or examples', () {
      expect(PromptConstants.systemMarkdownMap, contains('meow_core.db'));
      expect(
        promptClassifyAnalyzeRules,
        isNot(contains('meow_core.db')),
      );
      expect(promptClassifyResponseFormat, contains('subgoal_seeds'));
      expect(
        promptClassifyResponseFormat,
        isNot(contains('create 3')),
      );
    });

    test(
      'classify prompt does not inject heavy world model or database schema',
      () {
        final prompt = Classifier.buildPrompt(
          userMessage: 'show my tables',
          workspace: const AgentWorkspace(soul: 'User: Test'),
          snapshot: EcosystemSnapshot(
            agents: const [],
            workflows: const [],
            providers: const [],
            modules: const [],
            builtAt: DateTime(2026, 1, 1),
          ),
          availableTools: const [],
          language: DetectedLanguage.fromAnalyzerCode('en'),
          recentMessages: const [],
        );

        expect(prompt, contains('Predefined skill index'));
        expect(prompt, isNot(contains('System Database (meow_core.db')));
        expect(prompt, isNot(contains('World model (files.* tools)')));
        expect(prompt, isNot(contains('agent_soul(agent_id')));
        expect(prompt, isNot(contains('Documents/MeowAgent/Agents')));
      },
    );

    test('selected skill context is rendered outside execution plan dumps', () {
      final prompt = PromptTemplates.selectToolPrompt(
        plan: const {
          'main_goal': 'open app',
          '_selected_skill_context': 'meow.app detail',
        },
        currentStep: 1,
        previousResults: const [],
        availableTools: const ['- app.open: Open app'],
      );

      expect(prompt, contains('Selected skill context:'));
      expect(prompt, contains('meow.app detail'));
      expect(prompt, contains('main_goal: open app'));
      expect(prompt, isNot(contains('_selected_skill_context:')));
    });
  });
}
