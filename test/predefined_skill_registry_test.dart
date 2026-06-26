import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/predefined_skills/predefined_skills.dart';
import 'package:meow_agent/services/agent_runtime/runtime_module_plugins.dart';
import 'package:meow_agent/services/agent_runtime/tool_catalog.dart';

void main() {
  group('PredefinedSkillRegistry', () {
    test('skill ids are unique and stable-looking', () {
      final ids = PredefinedSkillRegistry.all.map((skill) => skill.id).toList();

      expect(ids.toSet(), hasLength(ids.length));
      for (final id in ids) {
        expect(id, startsWith('meow.'));
        expect(id, isNot(contains(' ')));
      }
    });

    test('master skill references registered module skills', () {
      final moduleIds = PredefinedSkillRegistry.skills
          .map((skill) => skill.id)
          .toSet();

      expect(
        PredefinedSkillRegistry.masterSkill.relatedSkillIds.toSet(),
        equals(moduleIds),
      );
    });

    test('referenced tool groups can narrow through ToolCatalog', () {
      for (final skill in PredefinedSkillRegistry.all) {
        if (skill.toolGroups.isEmpty) continue;

        final selection = ToolCatalog.fromGroups(skill.toolGroups);

        expect(
          selection.confidence,
          greaterThan(0),
          reason: '${skill.id} has unusable toolGroups: ${skill.toolGroups}',
        );
      }
    });

    test('module skill tool names exist in runtime modules', () {
      final registeredToolNames = buildRuntimeModuleRegistry().allToolNames;

      for (final skill in PredefinedSkillRegistry.skills) {
        final missing = skill.toolNames.toSet().difference(registeredToolNames);

        expect(
          missing,
          isEmpty,
          reason:
              '${skill.id} references tools that are not registered: $missing',
        );
      }
    });

    test('module skill tools are reachable from their tool groups', () {
      for (final skill in PredefinedSkillRegistry.skills) {
        final selection = ToolCatalog.fromGroups(skill.toolGroups);
        final unreachable = skill.toolNames.toSet().difference(
          selection.toolNames,
        );

        expect(
          unreachable,
          isEmpty,
          reason:
              '${skill.id} tools are not reachable from ${skill.toolGroups}: $unreachable',
        );
      }
    });

    test(
      'all registered runtime tools are covered by at least one module skill',
      () {
        final registeredToolNames = buildRuntimeModuleRegistry().allToolNames;
        final skillToolNames = PredefinedSkillRegistry.skills
            .expand((skill) => skill.toolNames)
            .toSet();

        final uncovered = registeredToolNames.difference(skillToolNames);

        expect(
          uncovered,
          isEmpty,
          reason:
              'Every registered tool should be represented by at least one predefined skill: $uncovered',
        );
      },
    );

    test('registry resolves known ids and ignores unknown ids', () {
      final resolved = PredefinedSkillRegistry.resolve([
        'meow.app',
        'meow.unknown',
        'meow.database',
      ]);

      expect(resolved.map((skill) => skill.id), ['meow.app', 'meow.database']);
    });
  });
}
