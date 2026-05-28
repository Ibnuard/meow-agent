import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/ecosystem_snapshot.dart';
import 'package:meow_agent/services/agent_runtime/goal_tree.dart';
import 'package:meow_agent/services/agent_runtime/language_detector.dart';
import 'package:meow_agent/services/agent_runtime/reflector.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';
import 'package:meow_agent/services/agent_runtime/target_resolution.dart';

void main() {
  final language = DetectedLanguage(
    code: 'id',
    label: 'Indonesian',
    script: 'Latin',
    confidence: 1,
  );

  AgentRuntimeRequest request({String agentId = 'mina'}) =>
      AgentRuntimeRequest(
        agentId: agentId,
        agentName: 'Mina',
        userMessage: 'hapus semua agent non planet',
      );

  EcosystemSnapshot snapshot() => EcosystemSnapshot(
        builtAt: DateTime(2026, 1, 1),
        agents: const [
          EcosystemAgent(
            id: 'mina',
            name: 'Mina',
            providerNickname: 'SUMOPOD',
            usedByWorkflows: ['Daily Mina'],
          ),
          EcosystemAgent(
            id: 'agent_a',
            name: 'Agent A',
            providerNickname: 'SUMOPOD',
            usedByWorkflows: ['Daily A'],
          ),
          EcosystemAgent(
            id: 'mars',
            name: 'Mars',
            providerNickname: 'SUMOPOD',
          ),
        ],
        workflows: const [
          EcosystemWorkflow(
            id: 'wf_mina',
            title: 'Daily Mina',
            agentId: 'mina',
            agentName: 'Mina',
            triggerSummary: 'daily',
            enabled: true,
          ),
          EcosystemWorkflow(
            id: 'wf_a',
            title: 'Daily A',
            agentId: 'agent_a',
            agentName: 'Agent A',
            triggerSummary: 'daily',
            enabled: true,
          ),
        ],
        providers: const [
          EcosystemProvider(id: 'p1', nickname: 'SUMOPOD'),
          EcosystemProvider(id: 'p2', nickname: '9ROUTER'),
        ],
        modules: const [],
      );

  group('TargetResolver', () {
    test('skips current active agent before impact filtering', () {
      final reflection = ReflectionOutput(
        strategy: ReflectionStrategy.clarify,
        goalTree: GoalTree(
          mainGoal: 'delete non planet agents',
          subgoals: [
            Subgoal(id: 'sg_mina', label: 'delete Mina'),
            Subgoal(id: 'sg_a', label: 'delete Agent A'),
          ],
        ),
        targets: const [
          ReflectionTarget(
            subgoalId: 'sg_mina',
            operation: 'delete',
            entityType: 'agent',
            entityId: 'mina',
            entityLabel: 'Mina',
          ),
          ReflectionTarget(
            subgoalId: 'sg_a',
            operation: 'delete',
            entityType: 'agent',
            entityId: 'agent_a',
            entityLabel: 'Agent A',
          ),
        ],
        impacts: const [
          ReflectionImpact(
            entityType: 'workflow',
            entityId: 'wf_mina',
            entityLabel: 'Daily Mina',
            relation: 'uses Mina',
            severity: 'high',
            autoResolvable: false,
            sourceTargetId: 'sg_mina',
          ),
          ReflectionImpact(
            entityType: 'workflow',
            entityId: 'wf_a',
            entityLabel: 'Daily A',
            relation: 'uses Agent A',
            severity: 'high',
            autoResolvable: false,
            sourceTargetId: 'sg_a',
          ),
        ],
      );

      final result = TargetResolver.resolveReflection(
        reflection: reflection,
        snapshot: snapshot(),
        request: request(),
        language: language,
      );

      expect(result.graph.skippedTargets.map((t) => t.entityLabel), ['Mina']);
      expect(result.graph.eligibleTargets.map((t) => t.entityLabel), [
        'Agent A',
      ]);
      expect(result.reflection.goalTree.subgoals.map((s) => s.id), ['sg_a']);
      expect(result.reflection.impacts.map((i) => i.entityId), ['wf_a']);
    });

    test('drops unlinked impacts when valid targets are known', () {
      final reflection = ReflectionOutput(
        strategy: ReflectionStrategy.clarify,
        goalTree: GoalTree(
          mainGoal: 'create agents',
          subgoals: [
            Subgoal(id: 'sg_bumi', label: 'create Bumi'),
          ],
        ),
        targets: const [
          ReflectionTarget(
            subgoalId: 'sg_bumi',
            operation: 'create',
            entityType: 'agent',
            entityLabel: 'Bumi',
          ),
        ],
        impacts: const [
          ReflectionImpact(
            entityType: 'provider',
            entityId: 'p1',
            entityLabel: 'SUMOPOD',
            relation: 'provider choice might matter',
            severity: 'low',
            autoResolvable: true,
          ),
        ],
        clarifyQuestions: const ['Mau pakai provider mana?'],
      );

      final result = TargetResolver.resolveReflection(
        reflection: reflection,
        snapshot: snapshot(),
        request: request(),
        language: language,
      );

      expect(result.reflection.impacts, isEmpty);
      expect(result.reflection.strategy, ReflectionStrategy.directExecute);
      expect(result.reflection.clarifyQuestions, isEmpty);
    });

    test('blocks when every target is policy-skipped', () {
      final reflection = ReflectionOutput(
        strategy: ReflectionStrategy.directExecute,
        goalTree: GoalTree(
          mainGoal: 'delete Mina',
          subgoals: [
            Subgoal(id: 'sg_mina', label: 'delete Mina'),
          ],
        ),
        targets: const [
          ReflectionTarget(
            subgoalId: 'sg_mina',
            operation: 'delete',
            entityType: 'agent',
            entityId: 'mina',
            entityLabel: 'Mina',
          ),
        ],
      );

      final result = TargetResolver.resolveReflection(
        reflection: reflection,
        snapshot: snapshot(),
        request: request(),
        language: language,
      );

      expect(result.reflection.strategy, ReflectionStrategy.block);
      expect(result.reflection.goalTree.subgoals, isEmpty);
      expect(result.reflection.blockReason, isNotEmpty);
    });

    test('clarifies when existing target operation cannot resolve target', () {
      final reflection = ReflectionOutput(
        strategy: ReflectionStrategy.directExecute,
        goalTree: GoalTree(
          mainGoal: 'delete Ghost',
          subgoals: [
            Subgoal(id: 'sg_ghost', label: 'delete Ghost'),
          ],
        ),
        targets: const [
          ReflectionTarget(
            subgoalId: 'sg_ghost',
            operation: 'delete',
            entityType: 'agent',
            entityLabel: 'Ghost',
          ),
        ],
      );

      final result = TargetResolver.resolveReflection(
        reflection: reflection,
        snapshot: snapshot(),
        request: request(),
        language: language,
      );

      expect(result.reflection.strategy, ReflectionStrategy.clarify);
      expect(result.reflection.clarifyQuestions.single, contains('Ghost'));
      expect(result.graph.blockingTargets.single.reason, 'target_not_found');
    });
  });
}
