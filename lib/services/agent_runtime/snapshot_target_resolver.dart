import 'ecosystem_snapshot.dart';
import 'entity_resolver.dart';

enum SnapshotTargetMatchKind { exact, ambiguous, missing, unsupported }

class SnapshotTargetCandidate {
  const SnapshotTargetCandidate({
    required this.entityType,
    required this.id,
    required this.label,
  });

  final String entityType;
  final String id;
  final String label;
}

class SnapshotTargetMatch {
  const SnapshotTargetMatch({
    required this.kind,
    required this.entityType,
    this.id = '',
    this.label = '',
    this.suggestions = const [],
  });

  final SnapshotTargetMatchKind kind;
  final String entityType;
  final String id;
  final String label;
  final List<String> suggestions;

  bool get isExact => kind == SnapshotTargetMatchKind.exact;
  bool get isAmbiguous => kind == SnapshotTargetMatchKind.ambiguous;
  bool get isMissing => kind == SnapshotTargetMatchKind.missing;
  bool get isUnsupported => kind == SnapshotTargetMatchKind.unsupported;
}

class SnapshotTargetResolver {
  SnapshotTargetResolver._();

  static bool isSnapshotBacked(String entityType) {
    switch (_normalize(entityType)) {
      case 'agent':
      case 'workflow':
      case 'provider':
      case 'module':
        return true;
      default:
        return false;
    }
  }

  static List<SnapshotTargetCandidate> candidates(
    EcosystemSnapshot snapshot,
    String entityType,
  ) {
    switch (_normalize(entityType)) {
      case 'agent':
        return [
          for (final agent in snapshot.agents)
            SnapshotTargetCandidate(
              entityType: 'agent',
              id: agent.id,
              label: agent.name,
            ),
        ];
      case 'workflow':
        return [
          for (final workflow in snapshot.workflows)
            SnapshotTargetCandidate(
              entityType: 'workflow',
              id: workflow.id,
              label: workflow.title,
            ),
        ];
      case 'provider':
        return [
          for (final provider in snapshot.providers)
            SnapshotTargetCandidate(
              entityType: 'provider',
              id: provider.id,
              label: provider.nickname,
            ),
        ];
      case 'module':
        return [
          for (final module in snapshot.modules)
            SnapshotTargetCandidate(
              entityType: 'module',
              id: module.id,
              label: module.id,
            ),
        ];
      default:
        return const [];
    }
  }

  static SnapshotTargetMatch resolve({
    required EcosystemSnapshot snapshot,
    required String entityType,
    String entityId = '',
    String entityLabel = '',
  }) {
    final normalizedType = _normalize(entityType);
    if (!isSnapshotBacked(normalizedType)) {
      return SnapshotTargetMatch(
        kind: SnapshotTargetMatchKind.unsupported,
        entityType: normalizedType,
      );
    }

    final list = candidates(snapshot, normalizedType);
    if (list.isEmpty) {
      return SnapshotTargetMatch(
        kind: SnapshotTargetMatchKind.missing,
        entityType: normalizedType,
      );
    }

    final normalizedId = _normalize(entityId);
    for (final candidate in list) {
      if (normalizedId.isNotEmpty && _normalize(candidate.id) == normalizedId) {
        return SnapshotTargetMatch(
          kind: SnapshotTargetMatchKind.exact,
          entityType: candidate.entityType,
          id: candidate.id,
          label: candidate.label,
        );
      }
    }

    final normalizedLabel = _normalize(entityLabel);
    for (final candidate in list) {
      if (normalizedLabel.isNotEmpty &&
          _normalize(candidate.label) == normalizedLabel) {
        return SnapshotTargetMatch(
          kind: SnapshotTargetMatchKind.exact,
          entityType: candidate.entityType,
          id: candidate.id,
          label: candidate.label,
        );
      }
    }

    if (normalizedLabel.isEmpty) {
      return SnapshotTargetMatch(
        kind: SnapshotTargetMatchKind.missing,
        entityType: normalizedType,
        suggestions: list.take(3).map((c) => c.label).toList(),
      );
    }

    final fuzzy = EntityResolver.resolve(entityLabel, list.map((c) => c.label));
    if (fuzzy.isNear && fuzzy.matched != null) {
      final matched = list.firstWhere(
        (c) => _normalize(c.label) == _normalize(fuzzy.matched!),
      );
      return SnapshotTargetMatch(
        kind: SnapshotTargetMatchKind.ambiguous,
        entityType: matched.entityType,
        id: matched.id,
        label: matched.label,
        suggestions: fuzzy.suggestions.isEmpty
            ? [matched.label]
            : fuzzy.suggestions,
      );
    }

    return SnapshotTargetMatch(
      kind: SnapshotTargetMatchKind.missing,
      entityType: normalizedType,
      suggestions: fuzzy.suggestions.isEmpty
          ? list.take(3).map((c) => c.label).toList()
          : fuzzy.suggestions,
    );
  }

  static String _normalize(String value) => value.trim().toLowerCase();
}
