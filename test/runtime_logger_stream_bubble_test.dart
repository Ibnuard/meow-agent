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

    test(
      'drops low-value progress bubbles and deduplicates semantic repeats',
      () {
        final logger = RuntimeLogger();

        expect(
          logger.logStreamBubble(
            kind: 'analysis_summary',
            phase: 'analyze',
            message: 'I will update the nickname.',
            evidenceRefs: const ['analysis:1'],
            contextPolicy: 'exclude',
          ),
          false,
        );
        expect(
          logger.logStreamBubble(
            kind: 'tool_failure',
            phase: 'review',
            message: 'Storage is full.',
            evidenceRefs: const ['result:1'],
            contextPolicy: 'exclude',
          ),
          true,
        );
        expect(
          logger.logStreamBubble(
            kind: 'warning',
            phase: 'review',
            message: 'Storage is full.',
            evidenceRefs: const ['selection:2'],
            contextPolicy: 'exclude',
          ),
          false,
        );
        expect(logger.events, hasLength(1));
      },
    );
  });
}
