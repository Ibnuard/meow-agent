import 'package:flutter_test/flutter_test.dart';

import 'package:meow_agent/services/agent_runtime/entity_resolver.dart';

void main() {
  group('EntityResolver.levenshtein', () {
    test('identical strings have distance 0', () {
      expect(EntityResolver.levenshtein('writer', 'writer'), 0);
    });

    test('empty strings handled', () {
      expect(EntityResolver.levenshtein('', 'abc'), 3);
      expect(EntityResolver.levenshtein('abc', ''), 3);
      expect(EntityResolver.levenshtein('', ''), 0);
    });

    test('single substitution', () {
      expect(EntityResolver.levenshtein('writer', 'wrater'), 1);
    });

    test('typo example from user (treaearcher vs researcher)', () {
      // Real bug case: user typed "treaearcher" meaning "researcher".
      // Both 11 chars. Differences: 't' inserted at start, 'a' inserted,
      // 'e' shifted — distance is small enough to be a near-match.
      final d = EntityResolver.levenshtein('treaearcher', 'researcher');
      expect(d, lessThanOrEqualTo(4));
    });

    test('completely different strings have large distance', () {
      expect(
        EntityResolver.levenshtein('writer', 'tornado'),
        greaterThanOrEqualTo(5),
      );
    });
  });

  group('EntityResolver.resolve', () {
    test('exact match wins regardless of case/whitespace', () {
      final m = EntityResolver.resolve('  Writer ', const [
        'Coder',
        'Writer',
        'Researcher',
      ]);
      expect(m.kind, EntityMatchKind.exact);
      expect(m.matched, 'Writer');
    });

    test('1-char typo is near-match', () {
      final m = EntityResolver.resolve('Wrtier', const [
        'Coder',
        'Writer',
        'Researcher',
      ]);
      expect(m.kind, EntityMatchKind.near);
      expect(m.matched, 'Writer');
    });

    test('2-char typo is still near-match', () {
      final m = EntityResolver.resolve('Writter', const [
        'Coder',
        'Writer',
        'Researcher',
      ]);
      expect(m.kind, EntityMatchKind.near);
      expect(m.matched, 'Writer');
    });

    test('unique partial agent name asks for confirmation as near-match', () {
      final m = EntityResolver.resolve('Mina', const [
        'Mina Chan',
        'Mars',
        'Programmer',
      ]);
      expect(m.kind, EntityMatchKind.near);
      expect(m.matched, 'Mina Chan');
    });

    test('ambiguous partial name returns suggestions instead of matching', () {
      final m = EntityResolver.resolve('Mina', const [
        'Mina Chan',
        'Mina Writer',
        'Mars',
      ]);
      expect(m.kind, EntityMatchKind.none);
      expect(m.suggestions, ['Mina Chan', 'Mina Writer']);
    });

    test('workspace-safe separators normalize like spaces', () {
      final m = EntityResolver.resolve('Mina_Chan', const [
        'Mina Chan',
        'Mars',
      ]);
      expect(m.kind, EntityMatchKind.exact);
      expect(m.matched, 'Mina Chan');
    });

    test('large distance returns none with suggestions', () {
      final m = EntityResolver.resolve('Tornado', const [
        'Coder',
        'Writer',
        'Researcher',
      ]);
      expect(m.kind, EntityMatchKind.none);
      expect(m.suggestions, isNotEmpty);
      expect(m.suggestions.length, lessThanOrEqualTo(3));
    });

    test('empty needle returns none', () {
      final m = EntityResolver.resolve('   ', const ['Writer']);
      expect(m.kind, EntityMatchKind.none);
      expect(m.suggestions, isEmpty);
    });

    test('empty candidates returns none', () {
      final m = EntityResolver.resolve('Writer', const []);
      expect(m.kind, EntityMatchKind.none);
    });

    test(
      'case-insensitive exact match takes priority over closer near-match',
      () {
        // "WRITER" should exact-match "writer" rather than near-match "Writer".
        final m = EntityResolver.resolve('WRITER', const ['writer', 'Writter']);
        expect(m.kind, EntityMatchKind.exact);
        expect(m.matched, 'writer');
      },
    );
  });

  group('EntityMatch convenience accessors', () {
    test('isExact / isNear / isMissing reflect kind', () {
      final exact = EntityResolver.resolve('a', const ['a']);
      expect(exact.isExact, true);
      expect(exact.isNear, false);
      expect(exact.isMissing, false);

      final near = EntityResolver.resolve('writter', const ['writer']);
      expect(near.isNear, true);
      expect(near.isExact, false);

      final none = EntityResolver.resolve('xyz', const ['abc', 'def', 'ghi']);
      expect(none.isMissing, true);
      expect(none.isExact, false);
      expect(none.isNear, false);
    });
  });
}
