import 'package:flutter_test/flutter_test.dart';

import 'package:meow_agent/services/agent_runtime/ecosystem_snapshot.dart';
import 'package:meow_agent/services/agent_runtime/reflector.dart';
import 'package:meow_agent/services/agent_runtime/goal_tree.dart';

void main() {
  group('EcosystemSnapshot — relevance heuristic', () {
    EcosystemSnapshot snapshot({
      List<EcosystemAgent> agents = const [],
      List<EcosystemWorkflow> workflows = const [],
      List<EcosystemModule> modules = const [],
      List<EcosystemProvider> providers = const [],
    }) =>
        EcosystemSnapshot(
          agents: agents,
          workflows: workflows,
          providers: providers,
          modules: modules,
          builtAt: DateTime(2026, 5, 28, 6, 0),
        );

    test('empty snapshot is not relevant', () {
      expect(snapshot().isRelevantForReflection, false);
    });

    test('single agent + no workflows + all modules enabled = not relevant', () {
      final snap = snapshot(
        agents: const [
          EcosystemAgent(
              id: 'a1', name: 'Solo', providerNickname: 'OpenRouter'),
        ],
        modules: const [
          EcosystemModule(id: 'notes', enabled: true),
        ],
      );
      expect(snap.isRelevantForReflection, false);
    });

    test('two agents triggers relevance (rename/delete impact possible)', () {
      final snap = snapshot(
        agents: const [
          EcosystemAgent(id: 'a1', name: 'A', providerNickname: 'p'),
          EcosystemAgent(id: 'a2', name: 'B', providerNickname: 'p'),
        ],
      );
      expect(snap.isRelevantForReflection, true);
    });

    test('workflow presence triggers relevance regardless of agent count', () {
      final snap = snapshot(
        agents: const [
          EcosystemAgent(id: 'a1', name: 'A', providerNickname: 'p'),
        ],
        workflows: const [
          EcosystemWorkflow(
            id: 'w1',
            title: 'Morning Brief',
            agentId: 'a1',
            agentName: 'A',
            triggerSummary: 'cron 8am',
            enabled: true,
          ),
        ],
      );
      expect(snap.isRelevantForReflection, true);
    });

    test('disabled module triggers relevance (permission may bite later)', () {
      final snap = snapshot(
        modules: const [
          EcosystemModule(id: 'notes', enabled: false),
        ],
      );
      expect(snap.isRelevantForReflection, true);
    });
  });

  group('EcosystemSnapshot — toCompactString', () {
    test('lists agents with workflow back-references', () {
      final snap = EcosystemSnapshot(
        agents: const [
          EcosystemAgent(
            id: 'a1',
            name: 'Coder',
            providerNickname: 'OpenRouter',
            usedByWorkflows: ['Morning Brief', 'Standup'],
          ),
          EcosystemAgent(
              id: 'a2', name: 'Writer', providerNickname: 'Groq'),
        ],
        workflows: const [],
        providers: const [],
        modules: const [],
        builtAt: DateTime(2026, 5, 28, 6, 0),
      );
      final out = snap.toCompactString();
      expect(out, contains('Coder'));
      expect(out, contains('OpenRouter'));
      expect(out, contains('used_by:[Morning Brief, Standup]'));
      expect(out, contains('Writer'));
    });

    test('marks disabled modules with (off) suffix', () {
      final snap = EcosystemSnapshot(
        agents: const [],
        workflows: const [],
        providers: const [],
        modules: const [
          EcosystemModule(id: 'notes', enabled: true),
          EcosystemModule(id: 'calendar', enabled: false),
        ],
        builtAt: DateTime(2026, 5, 28, 6, 0),
      );
      final out = snap.toCompactString();
      expect(out, contains('1/2 enabled'));
      expect(out, contains('notes'));
      expect(out, contains('calendar(off)'));
    });

    test('skips empty sections to keep prompt compact', () {
      final snap = EcosystemSnapshot(
        agents: const [],
        workflows: const [],
        providers: const [],
        modules: const [],
        builtAt: DateTime(2026, 5, 28, 6, 0),
      );
      final out = snap.toCompactString();
      expect(out, contains('Agents: none'));
      expect(out, isNot(contains('Workflows')));
      expect(out, isNot(contains('Providers')));
      expect(out, isNot(contains('Modules')));
    });
  });

  group('ReflectionStrategy parsing', () {
    test('parses canonical labels', () {
      expect(
        ReflectionStrategyX.fromLabel('direct_execute'),
        ReflectionStrategy.directExecute,
      );
      expect(
        ReflectionStrategyX.fromLabel('clarify'),
        ReflectionStrategy.clarify,
      );
      expect(
        ReflectionStrategyX.fromLabel('auto_resolve'),
        ReflectionStrategy.autoResolve,
      );
      expect(
        ReflectionStrategyX.fromLabel('block'),
        ReflectionStrategy.block,
      );
    });

    test('parses common alias variants', () {
      expect(
        ReflectionStrategyX.fromLabel('execute'),
        ReflectionStrategy.directExecute,
      );
      expect(
        ReflectionStrategyX.fromLabel('ask'),
        ReflectionStrategy.clarify,
      );
      expect(
        ReflectionStrategyX.fromLabel('resolve'),
        ReflectionStrategy.autoResolve,
      );
      expect(
        ReflectionStrategyX.fromLabel('refuse'),
        ReflectionStrategy.block,
      );
    });

    test('null/garbage falls back to directExecute (most permissive)', () {
      expect(
        ReflectionStrategyX.fromLabel(null),
        ReflectionStrategy.directExecute,
      );
      expect(
        ReflectionStrategyX.fromLabel('purple_monkey'),
        ReflectionStrategy.directExecute,
      );
    });

    test('label round-trips through toJson', () {
      expect(ReflectionStrategy.directExecute.label, 'direct_execute');
      expect(ReflectionStrategy.clarify.label, 'clarify');
      expect(ReflectionStrategy.autoResolve.label, 'auto_resolve');
      expect(ReflectionStrategy.block.label, 'block');
    });
  });

  group('ReflectionImpact JSON round-trip', () {
    test('preserves all fields including resolution hint', () {
      final impact = ReflectionImpact(
        entityType: 'workflow',
        entityId: 'wf_42',
        entityLabel: 'Morning Brief',
        relation: 'uses agent Coder',
        severity: 'high',
        autoResolvable: true,
        resolutionHint: 'reassign to Writer',
      );
      final restored = ReflectionImpact.fromJson(impact.toJson());
      expect(restored.entityType, impact.entityType);
      expect(restored.entityId, impact.entityId);
      expect(restored.entityLabel, impact.entityLabel);
      expect(restored.relation, impact.relation);
      expect(restored.severity, impact.severity);
      expect(restored.autoResolvable, impact.autoResolvable);
      expect(restored.resolutionHint, impact.resolutionHint);
    });

    test('tolerates missing optional fields with safe defaults', () {
      final restored = ReflectionImpact.fromJson({
        'entity_type': 'agent',
        'entity_id': 'a1',
        'entity_label': 'Coder',
        'relation': 'target',
      });
      expect(restored.severity, 'low');
      expect(restored.autoResolvable, false);
      expect(restored.resolutionHint, '');
    });
  });

  group('ReflectionOutput', () {
    test('toJson omits empty optional sections', () {
      final out = ReflectionOutput(
        strategy: ReflectionStrategy.directExecute,
        goalTree: GoalTree.singleSubgoal(
          mainGoal: 'open spotify',
          subgoalLabel: 'open spotify',
        ),
      );
      final json = out.toJson();
      expect(json.containsKey('impacts'), false);
      expect(json.containsKey('clarify_questions'), false);
      expect(json.containsKey('block_reason'), false);
      expect(json['strategy'], 'direct_execute');
    });

    test('hasImpacts reflects impacts list', () {
      final empty = ReflectionOutput(
        strategy: ReflectionStrategy.directExecute,
        goalTree: GoalTree.singleSubgoal(mainGoal: 'm', subgoalLabel: 'm'),
      );
      expect(empty.hasImpacts, false);

      final populated = ReflectionOutput(
        strategy: ReflectionStrategy.autoResolve,
        goalTree: GoalTree.singleSubgoal(mainGoal: 'm', subgoalLabel: 'm'),
        impacts: const [
          ReflectionImpact(
            entityType: 'workflow',
            entityId: 'w1',
            entityLabel: 'Morning Brief',
            relation: 'uses agent',
            severity: 'high',
            autoResolvable: true,
          ),
        ],
      );
      expect(populated.hasImpacts, true);
    });

    test('degraded flag carried through toJson', () {
      final out = ReflectionOutput(
        strategy: ReflectionStrategy.directExecute,
        goalTree: GoalTree.singleSubgoal(mainGoal: 'm', subgoalLabel: 'm'),
        degraded: true,
      );
      expect(out.toJson()['degraded'], true);
    });
  });
}
