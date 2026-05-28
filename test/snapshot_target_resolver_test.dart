import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/ecosystem_snapshot.dart';
import 'package:meow_agent/services/agent_runtime/snapshot_target_resolver.dart';

void main() {
  EcosystemSnapshot snapshot() => EcosystemSnapshot(
    builtAt: DateTime(2026, 1, 1),
    agents: const [
      EcosystemAgent(id: 'a1', name: 'Mina Chan', providerNickname: 'P1'),
    ],
    workflows: const [
      EcosystemWorkflow(
        id: 'wf1',
        title: 'Morning Brief',
        agentId: 'a1',
        agentName: 'Mina Chan',
        triggerSummary: 'daily',
        enabled: true,
      ),
    ],
    providers: const [EcosystemProvider(id: 'p1', nickname: 'SUMOPOD AI')],
    modules: const [EcosystemModule(id: 'files', enabled: true)],
  );

  group('SnapshotTargetResolver', () {
    test('resolves exact labels for every snapshot-backed entity type', () {
      final snap = snapshot();

      expect(
        SnapshotTargetResolver.resolve(
          snapshot: snap,
          entityType: 'agent',
          entityLabel: 'Mina Chan',
        ).id,
        'a1',
      );
      expect(
        SnapshotTargetResolver.resolve(
          snapshot: snap,
          entityType: 'workflow',
          entityLabel: 'Morning Brief',
        ).id,
        'wf1',
      );
      expect(
        SnapshotTargetResolver.resolve(
          snapshot: snap,
          entityType: 'provider',
          entityLabel: 'SUMOPOD AI',
        ).id,
        'p1',
      );
      expect(
        SnapshotTargetResolver.resolve(
          snapshot: snap,
          entityType: 'module',
          entityLabel: 'files',
        ).id,
        'files',
      );
    });

    test('partial labels become ambiguous instead of silently resolving', () {
      final match = SnapshotTargetResolver.resolve(
        snapshot: snapshot(),
        entityType: 'agent',
        entityLabel: 'Mina',
      );

      expect(match.kind, SnapshotTargetMatchKind.ambiguous);
      expect(match.id, 'a1');
      expect(match.label, 'Mina Chan');
    });

    test('unsupported domain targets are left to domain tools', () {
      final match = SnapshotTargetResolver.resolve(
        snapshot: snapshot(),
        entityType: 'file',
        entityLabel: 'Agents/Mina/SOUL.md',
      );

      expect(match.kind, SnapshotTargetMatchKind.unsupported);
    });
  });
}
