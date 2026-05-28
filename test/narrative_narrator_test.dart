import 'package:flutter_test/flutter_test.dart';

import 'package:meow_agent/services/agent_runtime/narrative_narrator.dart';

void main() {
  group('NarrativeNarrator', () {
    test('every known phase has Indonesian + English text', () {
      for (final phase in NarrativeNarrator.phases) {
        final id = NarrativeNarrator.narrate(phase, 'id');
        final en = NarrativeNarrator.narrate(phase, 'en');
        expect(id, isNotEmpty, reason: 'id missing for $phase');
        expect(en, isNotEmpty, reason: 'en missing for $phase');
        // Should NOT leak the raw phase key.
        expect(id, isNot(equals(phase)));
        expect(en, isNot(equals(phase)));
      }
    });

    test('unknown language falls back to English bundle', () {
      // 'xx' is not a real language code; should fall back gracefully.
      final out = NarrativeNarrator.narrate('planning', 'xx');
      final en = NarrativeNarrator.narrate('planning', 'en');
      expect(out, equals(en));
    });

    test('unknown phase falls back to "composing" within the bundle', () {
      final out = NarrativeNarrator.narrate('not_a_real_phase', 'id');
      final composing = NarrativeNarrator.narrate('composing', 'id');
      expect(out, equals(composing));
    });

    test('phrases never expose technical jargon', () {
      // Sample check across a few languages — confirms POV-AI tone.
      final forbidden = [
        'tool',
        'llm',
        'prompt',
        'subgoal',
        'goal_tree',
        'state_change',
        'system.',
      ];
      for (final lang in ['id', 'en', 'ja', 'es']) {
        for (final phase in NarrativeNarrator.phases) {
          final s = NarrativeNarrator.narrate(phase, lang).toLowerCase();
          for (final bad in forbidden) {
            expect(
              s.contains(bad),
              isFalse,
              reason: '"$lang/$phase" leaks "$bad": $s',
            );
          }
        }
      }
    });
  });

  group('NarrativePhaseMapper', () {
    test('common runtime states map to phases', () {
      expect(NarrativePhaseMapper.phaseForState('analyzing'), 'understanding');
      expect(NarrativePhaseMapper.phaseForState('planning'), 'planning');
      expect(NarrativePhaseMapper.phaseForState('selectingTool'), 'choosing');
      expect(NarrativePhaseMapper.phaseForState('executingTool'), 'executing');
      expect(NarrativePhaseMapper.phaseForState('waitingConfirmation'),
          'confirming');
      expect(NarrativePhaseMapper.phaseForState('reviewing'), 'reviewing');
      expect(NarrativePhaseMapper.phaseForState('askingUser'), 'asking');
    });

    test('terminal states return null so the bubble can clear', () {
      expect(NarrativePhaseMapper.phaseForState('done'), isNull);
      expect(NarrativePhaseMapper.phaseForState('failed'), isNull);
    });

    test('unknown state name returns null', () {
      expect(NarrativePhaseMapper.phaseForState('garbage'), isNull);
    });

    test('reflect message hint maps to reflecting', () {
      expect(
        NarrativePhaseMapper.phaseForMessage('Reflecting on impact'),
        'reflecting',
      );
    });

    test('retry message hint maps to recovering', () {
      expect(
        NarrativePhaseMapper.phaseForMessage('Tool failed, retry attempt 1'),
        'recovering',
      );
    });

    test('language detection event hint maps to understanding', () {
      expect(
        NarrativePhaseMapper.phaseForMessage('Language detected: id'),
        'understanding',
      );
    });

    test('unrecognized message returns null', () {
      expect(NarrativePhaseMapper.phaseForMessage('idle'), isNull);
    });
  });
}
