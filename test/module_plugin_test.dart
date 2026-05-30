import 'package:flutter_test/flutter_test.dart';

import 'package:meow_agent/features/modules/notes/notes_module.dart';
import 'package:meow_agent/services/agent_runtime/module_registry.dart';
import 'package:meow_agent/services/agent_runtime/tool_catalog.dart';
import 'package:meow_agent/services/agent_runtime/tool_router.dart';

/// Stage 3 guard: the self-registering module architecture must keep the
/// router registry and the catalog group map in sync. A tool that exists in
/// one but not the other is the exact "silent-drop" hazard the refactor
/// removes — so any drift is a hard test failure, not a runtime surprise.
void main() {
  final router = ToolRouter();

  group('Module plugin registry', () {
    test('every catalog group tool is a registered router tool', () {
      final registered = router.registeredTools.toSet();
      final catalogTools = ToolCatalog.groups.values.expand((s) => s).toSet();
      final missingFromRegistry = catalogTools.difference(registered);
      expect(
        missingFromRegistry,
        isEmpty,
        reason:
            'Catalog lists tools the router does not register (would be '
            'shortlisted then fail validation): $missingFromRegistry',
      );
    });

    test('every registered router tool is reachable via the catalog', () {
      final registered = router.registeredTools.toSet();
      final catalogTools = ToolCatalog.groups.values.expand((s) => s).toSet();
      final missingFromCatalog = registered.difference(catalogTools);
      expect(
        missingFromCatalog,
        isEmpty,
        reason:
            'Router registers tools absent from the catalog groups (would be '
            'silent-dropped from the analyzer shortlist): $missingFromCatalog',
      );
    });

    test('router and catalog derive the same plugin group map', () {
      expect(router.catalogGroups, equals(ToolCatalog.groups));
    });
  });

  group('NotesModulePlugin migration', () {
    const plugin = NotesModulePlugin();

    test('registry derives all notes tools from the plugin', () {
      final registered = router.registeredTools.toSet();
      for (final name in plugin.toolNames) {
        expect(
          registered.contains(name),
          isTrue,
          reason: '$name should be derived into the router registry',
        );
        // Definition metadata must survive derivation (risk/confirmation are
        // the security-relevant fields).
        final def = router.getDefinition(name);
        expect(def, isNotNull, reason: '$name definition missing');
      }
    });

    test('notes tool definitions preserve risk + confirmation metadata', () {
      // Spot-check the security-relevant flags that drive the confirm gate.
      final create = router.getDefinition('notes.create')!;
      expect(create.risk, 'safe');
      expect(create.requiresConfirmation, false);

      final del = router.getDefinition('notes.delete')!;
      expect(del.risk, 'sensitive');
      expect(del.requiresConfirmation, true);
    });

    test('ModuleRegistry rejects duplicate tool ownership', () {
      expect(
        () => ModuleRegistry(const [NotesModulePlugin(), NotesModulePlugin()]),
        throwsStateError,
      );
    });
  });
}
