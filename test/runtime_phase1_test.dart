import 'package:flutter_test/flutter_test.dart';

import 'package:meow_agent/services/agent_runtime/i18n_fallback.dart';
import 'package:meow_agent/services/agent_runtime/language_detector.dart';
import 'package:meow_agent/services/agent_runtime/pending_action.dart';
import 'package:meow_agent/services/agent_runtime/workspace_loader.dart';

void main() {
  group('LanguageDetector — script-based', () {
    final detector = LanguageDetector();

    test('detects Japanese from kana', () {
      final result = detector.detect(
        userMessage: 'こんにちは、エージェントを作って',
        fallbackCode: 'en',
      );
      expect(result.code, 'ja');
      expect(result.script, 'Japanese');
      expect(result.isHighConfidence, true);
    });

    test('detects Korean (Hangul)', () {
      final result = detector.detect(
        userMessage: '에이전트를 만들어 주세요',
        fallbackCode: 'en',
      );
      expect(result.code, 'ko');
      expect(result.script, 'Hangul');
    });

    test('detects Chinese (Han, no kana)', () {
      final result = detector.detect(
        userMessage: '请帮我创建一个新代理',
        fallbackCode: 'en',
      );
      expect(result.code, 'zh');
      expect(result.script, 'Han');
    });

    test('detects Cyrillic → Russian', () {
      final result = detector.detect(
        userMessage: 'Создай нового агента',
        fallbackCode: 'en',
      );
      expect(result.code, 'ru');
      expect(result.script, 'Cyrillic');
    });

    test('detects Arabic', () {
      final result = detector.detect(
        userMessage: 'أنشئ وكيلاً جديداً',
        fallbackCode: 'en',
      );
      expect(result.code, 'ar');
      expect(result.script, 'Arabic');
    });

    test('detects Thai', () {
      final result = detector.detect(
        userMessage: 'สร้างเอเจนต์ใหม่',
        fallbackCode: 'en',
      );
      expect(result.code, 'th');
      expect(result.script, 'Thai');
    });
  });

  group('LanguageDetector — Latin probe', () {
    final detector = LanguageDetector();

    test('detects Indonesian from word markers', () {
      final result = detector.detect(
        userMessage: 'tolong buatkan saya catatan tentang ini',
        fallbackCode: 'en',
      );
      expect(result.code, 'id');
    });

    test('detects English from word markers', () {
      final result = detector.detect(
        userMessage: 'please create a note about this for me',
        fallbackCode: 'id',
      );
      expect(result.code, 'en');
    });

    test('falls back when neither ID nor EN markers hit', () {
      final result = detector.detect(
        userMessage: 'spotify',
        fallbackCode: 'id',
      );
      expect(result.code, 'id');
    });

    test('falls back when ID and EN tied', () {
      // Crafted so both score 0.
      final result = detector.detect(
        userMessage: 'xyz',
        fallbackCode: 'en',
      );
      expect(result.code, 'en');
    });
  });

  group('LanguageDetector — caching', () {
    test('returns cached result for same input', () {
      final detector = LanguageDetector();
      final a = detector.detect(
        userMessage: 'tolong buatkan saya catatan ini',
        fallbackCode: 'en',
      );
      final b = detector.detect(
        userMessage: 'tolong buatkan saya catatan ini',
        fallbackCode: 'en',
      );
      // Latin probe builds a new instance per call. If cache works, both
      // calls return the same instance.
      expect(identical(a, b), true);
    });

    test('clearCache evicts cached entries', () {
      final detector = LanguageDetector();
      final a = detector.detect(
        userMessage: 'tolong buatkan saya catatan ini',
        fallbackCode: 'en',
      );
      detector.clearCache();
      final b = detector.detect(
        userMessage: 'tolong buatkan saya catatan ini',
        fallbackCode: 'en',
      );
      expect(identical(a, b), false);
      expect(a.code, b.code); // same outcome, different instance
    });
  });

  group('I18nFallback', () {
    test('returns ID phrase for id+confirm', () {
      final s = I18nFallback.get('confirm', 'id');
      expect(s, contains('Lanjutkan'));
    });

    test('returns EN phrase for en+confirm', () {
      final s = I18nFallback.get('confirm', 'en');
      expect(s.toLowerCase(), contains('proceed'));
    });

    test('falls back to EN when language code unknown', () {
      final s = I18nFallback.get('cancel', 'xyz');
      expect(s.toLowerCase(), contains('cancel'));
    });

    test('returns error fallback when phase unknown', () {
      final s = I18nFallback.get('garbage_phase', 'en');
      expect(s.toLowerCase(), contains('went wrong'));
    });

    test('every supported language has all 6 phases', () {
      const phases = ['confirm', 'success', 'cancel', 'preview', 'abort', 'error'];
      const langs = ['id', 'en', 'ja', 'ko', 'zh', 'es', 'fr', 'de', 'pt',
                    'ru', 'ar', 'hi', 'vi', 'th', 'tr', 'ms', 'he'];
      for (final lang in langs) {
        for (final phase in phases) {
          final s = I18nFallback.get(phase, lang);
          expect(s.isNotEmpty, true,
              reason: 'Empty fallback for lang=$lang phase=$phase');
        }
      }
    });
  });

  group('ConfirmationChecker — whole-word matching', () {
    test('confirms on "ya"', () {
      expect(ConfirmationChecker.check('ya'), ConfirmationDecision.confirmed);
    });

    test('confirms on "yes please"', () {
      expect(
        ConfirmationChecker.check('yes please'),
        ConfirmationDecision.confirmed,
      );
    });

    test('rejects on "tidak"', () {
      expect(
        ConfirmationChecker.check('tidak'),
        ConfirmationDecision.rejected,
      );
    });

    test('rejects on "no thanks"', () {
      expect(
        ConfirmationChecker.check('no thanks'),
        ConfirmationDecision.rejected,
      );
    });

    test('detects preview from phrase', () {
      expect(
        ConfirmationChecker.check('lihat dulu hasilnya'),
        ConfirmationDecision.previewOnly,
      );
    });

    test('whole-word "ga" still rejects', () {
      expect(
        ConfirmationChecker.check('ga'),
        ConfirmationDecision.rejected,
      );
    });

    test('does NOT match "ga" inside "gambar" (no false positive)', () {
      // The old substring matcher would have flagged "ga " here. New matcher
      // tokenizes by word boundary, so "gambar" stays unmatched.
      expect(
        ConfirmationChecker.check('gambar'),
        ConfirmationDecision.unclear,
      );
    });

    test('returns unclear for unrelated message', () {
      expect(
        ConfirmationChecker.check('coba dulu deh nanti'),
        ConfirmationDecision.unclear,
      );
    });

    test('returns unclear for empty string', () {
      expect(ConfirmationChecker.check(''), ConfirmationDecision.unclear);
    });
  });

  group('PendingAction', () {
    test('round-trips through JSON with new fields', () {
      final p = PendingAction(
        toolName: 'system.agents.delete',
        toolArgs: const {'name': 'Bob'},
        userFacingSummary: 'Delete Bob?',
        userFacingPreview: 'Bob would be removed.',
        languageCode: 'en',
      );
      final restored = PendingAction.fromJson(p.toJson());
      expect(restored.toolName, p.toolName);
      expect(restored.toolArgs, p.toolArgs);
      expect(restored.userFacingSummary, p.userFacingSummary);
      expect(restored.userFacingPreview, p.userFacingPreview);
      expect(restored.languageCode, p.languageCode);
    });

    test('debugDescriptor never exposed to users; safe to log', () {
      final p = PendingAction(
        toolName: 'clipboard.write',
        toolArgs: const {'text': 'secret'},
        userFacingSummary: 'foo',
      );
      expect(p.debugDescriptor, contains('clipboard.write'));
    });
  });

  group('WorkspaceLoader.isUserNameMissing — introduction gate', () {
    test('empty SOUL.md → missing', () {
      expect(WorkspaceLoader.isUserNameMissing(''), true);
    });

    test('default placeholder "[Your Name]" → missing', () {
      const soul = '''# SOUL.md

## Agent Identity

Name: Spotify Agent

---

## User Identity

Name: [Your Name]
Nickname: [Optional Nickname]
Preferred Language: [Not set]
''';
      expect(WorkspaceLoader.isUserNameMissing(soul), true);
    });

    test('real name in User Identity → not missing', () {
      const soul = '''# SOUL.md

## Agent Identity

Name: Spotify Agent

---

## User Identity

Name: Budi
Nickname: Bud
''';
      expect(WorkspaceLoader.isUserNameMissing(soul), false);
    });

    test('User Identity section missing → missing', () {
      const soul = '''# SOUL.md

## Agent Identity

Name: Spotify Agent
''';
      expect(WorkspaceLoader.isUserNameMissing(soul), true);
    });

    test('User Identity > Name empty → missing', () {
      const soul = '''# SOUL.md

## User Identity

Name:
Nickname: [Optional Nickname]
''';
      expect(WorkspaceLoader.isUserNameMissing(soul), true);
    });

    test('agent identity name does not satisfy user identity gate', () {
      // The Agent Identity section contains "Name: Spotify Agent" but the
      // gate must look at User Identity specifically.
      const soul = '''# SOUL.md

## Agent Identity

Name: Spotify Agent
Role: Assistant

---

## User Identity

Name: [Your Name]
''';
      expect(WorkspaceLoader.isUserNameMissing(soul), true);
    });
  });

  group('PendingAction.resumeContext (multi-subgoal confirm fix)', () {
    test('defaults to null when not specified (backwards compat)', () {
      final p = PendingAction(
        toolName: 'system.agents.delete',
        toolArgs: const {'name': 'Writer'},
        userFacingSummary: 'Delete Writer?',
      );
      expect(p.resumeContext, isNull);
      expect(p.toJson().containsKey('resume'), isFalse);
    });

    test('round-trips a populated resume context through JSON', () {
      final ctx = <String, dynamic>{
        'plan': {
          'steps': [
            {'id': 1, 'description': 'delete writer', 'tool': null}
          ]
        },
        'goal_tree': {
          'main_goal': 'multi step',
          'completion_criteria': const [],
          'subgoals': [
            {
              'id': 'sg1',
              'label': 'delete Writer',
              'status': 'in_progress',
            },
            {
              'id': 'sg2',
              'label': 'create HOTDoG',
              'status': 'pending',
            },
            {
              'id': 'sg3',
              'label': 'update Researcher',
              'status': 'pending',
            },
          ],
        },
        'previous_results': const [],
        'current_step': 1,
        'available_tools': const ['system.agents.delete', 'system.agents.create'],
        'memory_snapshot': '',
        'auto_approve_sensitive': false,
        'is_workflow_auto_execute': false,
        'language_code': 'id',
        'language_label': 'Indonesian',
        'language_script': 'Latin',
        'language_confidence': 0.9,
        'user_message': 'tolong hapus Writer lalu buat HOTDoG dan ubah Researcher',
      };

      final original = PendingAction(
        toolName: 'system.agents.delete',
        toolArgs: const {'name': 'Writer'},
        userFacingSummary: 'Delete Writer?',
        userFacingPreview: 'will delete Writer',
        languageCode: 'id',
        resumeContext: ctx,
      );

      final restored = PendingAction.fromJson(original.toJson());
      expect(restored.resumeContext, isNotNull);
      expect(restored.resumeContext!['current_step'], 1);
      expect(restored.resumeContext!['language_code'], 'id');
      final tree = restored.resumeContext!['goal_tree'] as Map<String, dynamic>;
      final subgoals = tree['subgoals'] as List;
      expect(subgoals.length, 3);
      expect((subgoals[0] as Map)['status'], 'in_progress');
    });

    test('legacy JSON without resume field still parses cleanly', () {
      // Simulates a PendingAction persisted before this fix landed.
      final legacy = <String, dynamic>{
        'tool': 'clipboard.write',
        'args': const {'text': 'hello'},
        'summary': 'Write to clipboard?',
        'preview': '',
        'lang': 'en',
        'created_at': '2026-05-27T22:00:00.000Z',
      };
      final restored = PendingAction.fromJson(legacy);
      expect(restored.resumeContext, isNull);
      expect(restored.toolName, 'clipboard.write');
    });
  });
}
