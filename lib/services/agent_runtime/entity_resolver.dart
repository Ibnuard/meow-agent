/// Deterministic resolver for "does this name reference an existing entity?"
///
/// Used as a safety net in front of the confirmation gate so the runtime
/// catches typos like "treaearcher" before the user taps confirm and the
/// tool fails with "agent not found".
///
/// Two-stage match:
/// 1. Exact (case-insensitive, trimmed). Returns [EntityMatch.exact].
/// 2. Near-match via Levenshtein distance. Returns [EntityMatch.near] for
///    distances ≤ [nearMatchThreshold].
///
/// The reflector is the primary path for catching typos via the prompt rule.
/// This module is the deterministic backstop for cases where the LLM still
/// emits a non-existent target despite the rule.
class EntityResolver {
  EntityResolver._();

  /// Levenshtein distance threshold considered "plausible typo".
  /// Distance > this is treated as no near-match (block territory).
  static const int nearMatchThreshold = 2;

  /// Resolves [needle] against [candidates].
  ///
  /// Returns the best match by stage:
  /// - exact (case-insensitive trim) → [EntityMatch.exact]
  /// - distance ≤ threshold → [EntityMatch.near]
  /// - else → [EntityMatch.none] with [EntityMatch.suggestions] populated by
  ///   the closest 3 candidates (regardless of distance) so callers can show
  ///   "did you mean any of these?"
  static EntityMatch resolve(String needle, Iterable<String> candidates) {
    final normalizedNeedle = _normalize(needle);
    if (normalizedNeedle.isEmpty) {
      return EntityMatch._(
        kind: EntityMatchKind.none,
        suggestions: const [],
      );
    }

    final list = candidates.toList(growable: false);
    if (list.isEmpty) {
      return EntityMatch._(
        kind: EntityMatchKind.none,
        suggestions: const [],
      );
    }

    // 1. Exact match.
    for (final c in list) {
      if (_normalize(c) == normalizedNeedle) {
        return EntityMatch._(
          kind: EntityMatchKind.exact,
          matched: c,
          suggestions: const [],
        );
      }
    }

    // 2. Sort by distance.
    final scored = list
        .map((c) => _Scored(c, levenshtein(normalizedNeedle, _normalize(c))))
        .toList()
      ..sort((a, b) => a.distance.compareTo(b.distance));

    final best = scored.first;
    if (best.distance <= nearMatchThreshold) {
      return EntityMatch._(
        kind: EntityMatchKind.near,
        matched: best.value,
        suggestions: scored.take(3).map((s) => s.value).toList(),
      );
    }

    return EntityMatch._(
      kind: EntityMatchKind.none,
      suggestions: scored.take(3).map((s) => s.value).toList(),
    );
  }

  /// Standard Levenshtein edit distance. O(m·n) memory; fine for short
  /// entity names (< 100 chars). Iterative two-row implementation.
  static int levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    final m = a.length;
    final n = b.length;
    var prev = List<int>.generate(n + 1, (i) => i);
    var curr = List<int>.filled(n + 1, 0);

    for (var i = 1; i <= m; i++) {
      curr[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        curr[j] = [
          curr[j - 1] + 1, // insertion
          prev[j] + 1, // deletion
          prev[j - 1] + cost, // substitution
        ].reduce((x, y) => x < y ? x : y);
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }

    return prev[n];
  }

  static String _normalize(String s) => s.trim().toLowerCase();
}

class _Scored {
  const _Scored(this.value, this.distance);
  final String value;
  final int distance;
}

enum EntityMatchKind { exact, near, none }

class EntityMatch {
  const EntityMatch._({
    required this.kind,
    this.matched,
    this.suggestions = const [],
  });

  final EntityMatchKind kind;

  /// The matched candidate when [kind] is [EntityMatchKind.exact] or
  /// [EntityMatchKind.near]. Null when no match.
  final String? matched;

  /// Up to 3 closest candidates regardless of distance. Useful for the
  /// "no match" branch so the runtime can list options to the user.
  final List<String> suggestions;

  bool get isExact => kind == EntityMatchKind.exact;
  bool get isNear => kind == EntityMatchKind.near;
  bool get isMissing => kind == EntityMatchKind.none;
}
