import 'package:flutter_test/flutter_test.dart';

import 'package:meow_agent/features/modules/workflows/workflow_builtin_vars.dart';

void main() {
  group('step-result key predicates', () {
    test('isStepResultKey matches stepN only', () {
      expect(isStepResultKey('step1'), true);
      expect(isStepResultKey('step42'), true);
      expect(isStepResultKey('step'), false);
      expect(isStepResultKey('step0'), true); // numeric, even if unused
      expect(isStepResultKey('steps'), false);
      expect(isStepResultKey('prev'), false);
      expect(isStepResultKey('notif'), false);
    });

    test('stepResultNumber extracts the 1-based number', () {
      expect(stepResultNumber('step1'), 1);
      expect(stepResultNumber('step12'), 12);
      expect(stepResultNumber('prev'), isNull);
      expect(stepResultNumber('garbage'), isNull);
    });

    test('isKnownBuiltInKey covers static catalog and dynamic step keys', () {
      // Static
      expect(isKnownBuiltInKey('prev'), true);
      expect(isKnownBuiltInKey('notif'), true);
      expect(isKnownBuiltInKey('date'), true);
      // Dynamic
      expect(isKnownBuiltInKey('step1'), true);
      expect(isKnownBuiltInKey('step99'), true);
      // Unknown
      expect(isKnownBuiltInKey('foo'), false);
      expect(isKnownBuiltInKey('step_index'), false); // removed
    });
  });

  group('stepResultVariables generation', () {
    test('emits @step1..@step{N-1}, never the final step', () {
      // 3 steps → only step1, step2 (step3 output is never referenceable).
      final vars = stepResultVariables(3);
      expect(vars.map((v) => v.key).toList(), ['step1', 'step2']);
      expect(vars.every((v) => v.category == BuiltInCategory.step), true);
      expect(vars.first.placeholder, '@step1');
    });

    test('empty for < 2 steps', () {
      expect(stepResultVariables(0), isEmpty);
      expect(stepResultVariables(1), isEmpty);
    });

    test('scales with step count', () {
      expect(stepResultVariables(5).map((v) => v.key), [
        'step1',
        'step2',
        'step3',
        'step4',
      ]);
    });
  });

  group('catalog cleanup', () {
    test('step_index is removed but prev remains', () {
      final keys = kWorkflowBuiltInVariables.map((v) => v.key).toSet();
      expect(keys.contains('prev'), true);
      expect(keys.contains('step_index'), false);
    });

    test('notification context variables used by templates are registered', () {
      final keys = kWorkflowBuiltInVariables.map((v) => v.key).toSet();
      expect(keys.contains('notif'), true);
      expect(keys.contains('notif_title'), true);
      expect(keys.contains('notif_app'), true);
      expect(keys.contains('notif_body'), true);
      expect(keys.contains('notif_sender'), true);
      expect(keys.contains('notif_keyword'), true);
    });
  });

  group('substitute resolves dynamic step keys', () {
    test('@step1 / @step2 expand from the vars map', () {
      const prompt = 'Compare @step1 with @step2 and email @prev';
      final out = WorkflowBuiltInVars.substitute(prompt, {
        'step1': 'ALPHA',
        'step2': 'BETA',
        'prev': 'GAMMA',
      });
      expect(out, 'Compare ALPHA with BETA and email GAMMA');
    });

    test('unknown @stepN left intact when not in vars', () {
      const prompt = 'Use @step9 here';
      final out = WorkflowBuiltInVars.substitute(prompt, {'step1': 'X'});
      expect(out, 'Use @step9 here');
    });
  });
}
