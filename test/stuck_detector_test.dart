import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/goal_tree.dart';

void main() {
  group('StuckDetector', () {
    test('byte-identical calls trip at threshold', () {
      final d = StuckDetector();
      const args = {'id': 'x'};
      expect(d.observe(toolName: 't', args: args), isFalse);
      expect(d.observe(toolName: 't', args: args), isFalse);
      expect(d.observe(toolName: 't', args: args), isTrue);
    });

    test('semantic key trips when args vary but target is the same', () {
      // The loop the byte-identical detector would MISS: same tool + same
      // target entity, but an incidental arg (a query/note) changes each pass.
      final d = StuckDetector();
      expect(
        d.observe(
          toolName: 'agent.soul.read',
          args: const {'name': 'A', 'note': 'try 1'},
          target: 'name=A',
        ),
        isFalse,
      );
      expect(
        d.observe(
          toolName: 'agent.soul.read',
          args: const {'name': 'A', 'note': 'try 2'},
          target: 'name=A',
        ),
        isFalse,
      );
      expect(
        d.observe(
          toolName: 'agent.soul.read',
          args: const {'name': 'A', 'note': 'try 3'},
          target: 'name=A',
        ),
        isTrue,
      );
    });

    test('different targets do not trip', () {
      final d = StuckDetector();
      expect(
        d.observe(toolName: 't', args: const {}, target: 'name=A'),
        isFalse,
      );
      expect(
        d.observe(toolName: 't', args: const {}, target: 'name=B'),
        isFalse,
      );
      expect(
        d.observe(toolName: 't', args: const {}, target: 'name=C'),
        isFalse,
      );
    });

    test('reset clears the counters', () {
      final d = StuckDetector();
      const args = {'id': 'x'};
      d.observe(toolName: 't', args: args);
      d.observe(toolName: 't', args: args);
      d.reset();
      expect(d.observe(toolName: 't', args: args), isFalse);
    });
  });
}
