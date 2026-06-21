import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/runtime_logger.dart';

void main() {
  group('RuntimeLogger streamed bubbles', () {
    test('records phase-complete metadata and evidence', () {
      final logger = RuntimeLogger();

      final emitted = logger.logStreamBubble(
        kind: 'impact',
        phase: 'reflect',
        message: 'Table X already has column X.',
        evidenceRefs: const ['snapshot:42', 'table:x'],
        contextPolicy: 'include',
      );

      expect(emitted, true);
      expect(logger.events.single.type, 'stream_bubble');
      expect(logger.events.single.data, {
        'kind': 'impact',
        'phase': 'reflect',
        'evidence_refs': ['snapshot:42', 'table:x'],
        'context_policy': 'include',
      });
    });

    test('pre-action narrator is ephemeral and replaceable by phase', () {
      final logger = RuntimeLogger();

      expect(
        logger.logPreActionNarrative('planning', 'Next, I will plan.'),
        true,
      );
      expect(
        logger.logPreActionNarrative('planning', 'Next, I will plan.'),
        false,
      );
      expect(
        logger.logPreActionNarrative('reviewing', 'Next, I will review.'),
        true,
      );

      expect(logger.events, hasLength(2));
      expect(logger.events.last.type, 'narrative');
      expect(logger.events.last.data, {
        'phase': 'reviewing',
        'mode': 'pre_action',
      });
    });

    test('deduplicates only the same semantic checkpoint', () {
      final logger = RuntimeLogger();

      expect(
        logger.logStreamBubble(
          kind: 'tool_insight',
          phase: 'review',
          message: 'One row was inserted.',
          evidenceRefs: const ['result:1'],
          contextPolicy: 'exclude',
        ),
        true,
      );
      expect(
        logger.logStreamBubble(
          kind: 'tool_insight',
          phase: 'review',
          message: '  One row was inserted.  ',
          evidenceRefs: const ['result:1'],
          contextPolicy: 'exclude',
        ),
        false,
      );
      expect(
        logger.logStreamBubble(
          kind: 'next_action',
          phase: 'select_tool',
          message: 'One row was inserted. Next I will add Venus.',
          evidenceRefs: const ['selection:2'],
          contextPolicy: 'exclude',
        ),
        true,
      );
      expect(logger.events, hasLength(2));
    });
  });
}
