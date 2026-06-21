import 'package:flutter_test/flutter_test.dart';

import 'package:meow_agent/services/agent_runtime/tool_catalog.dart';

/// Stage 4 guard: tool shortlisting is driven by the analyzer's structured
/// `tool_groups` hint (English enums), NOT by language-specific keyword
/// matching. A miss/unknown hint must fall back to the full catalog so
/// accuracy is never sacrificed for token savings.
void main() {
  group('ToolCatalog.fromGroups', () {
    test('single valid group narrows to that group, high confidence', () {
      final sel = ToolCatalog.fromGroups(['device']);
      expect(sel.groups, {'device'});
      expect(sel.isHighConfidence, isTrue);
      expect(sel.toolNames, contains('device.battery'));
      expect(sel.toolNames, isNot(contains('notes.create')));
    });

    test('system group also pulls in files (config/spec pivots)', () {
      final sel = ToolCatalog.fromGroups(['system']);
      expect(sel.toolNames, contains('system.config.read'));
      expect(sel.toolNames, contains('files.read'));
    });

    test('multiple groups → moderate confidence, union of tools', () {
      final sel = ToolCatalog.fromGroups(['notes', 'calendar']);
      expect(sel.groups, {'notes', 'calendar'});
      expect(sel.isHighConfidence, isFalse);
      expect(sel.toolNames, contains('notes.create'));
      expect(sel.toolNames, contains('calendar.create'));
    });

    test('unknown group names are ignored', () {
      final sel = ToolCatalog.fromGroups(['device', 'totally_made_up']);
      expect(sel.groups, {'device'});
    });

    test(
      'empty/null hint falls back to the FULL catalog (never drops tools)',
      () {
        for (final hint in [
          null,
          <String>[],
          ['nonsense'],
        ]) {
          final sel = ToolCatalog.fromGroups(hint);
          // Full catalog = every tool in every group.
          final allTools = ToolCatalog.groups.values.expand((s) => s).toSet();
          expect(
            sel.toolNames,
            equals(allTools),
            reason: 'hint=$hint should fall back to full catalog',
          );
          expect(sel.isHighConfidence, isFalse);
        }
      },
    );

    test('group enum names are case/whitespace tolerant', () {
      final sel = ToolCatalog.fromGroups([' Device ', 'NOTES']);
      expect(sel.groups, {'device', 'notes'});
    });
  });
}
