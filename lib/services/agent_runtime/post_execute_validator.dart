import 'ecosystem_snapshot.dart';
import 'language_registry.dart';
import 'language_detector.dart';
import 'runtime_models.dart';
import 'snapshot_target_resolver.dart';

/// Outcome of a post-execute verification probe.
///
/// Three states:
/// - [ok]          — verified or no probe configured
/// - [unverified]  — probe ran but the expected post-state was NOT observed
/// - [skipped]     — probe could not run (no snapshot, no selector, etc.)
class PostExecuteVerification {
  const PostExecuteVerification._({
    required this.status,
    this.expectedEntity = '',
    this.entityType = '',
    this.reason = '',
  });

  final PostExecuteStatus status;

  /// The label of the entity the probe expected (e.g. agent name "Mars").
  final String expectedEntity;

  /// Snapshot entity type the probe targeted (`agent`, `workflow`, ...).
  final String entityType;

  /// Short English reason — used for logs, not for the user.
  final String reason;

  bool get isOk => status == PostExecuteStatus.ok;
  bool get isUnverified => status == PostExecuteStatus.unverified;
  bool get isSkipped => status == PostExecuteStatus.skipped;

  /// User-facing message in the user's language explaining the failure.
  /// Returns empty string when [isOk] or [isSkipped].
  String userFacingMessage(DetectedLanguage language) {
    if (!isUnverified) return '';
    if (expectedEntity.isNotEmpty) {
      return LanguageRegistry.phrase('completion_unverified', language.code, {
        'entity': expectedEntity,
      });
    }
    return LanguageRegistry.phrase(
      'completion_unverified_generic',
      language.code,
    );
  }

  static const PostExecuteVerification ok = PostExecuteVerification._(
    status: PostExecuteStatus.ok,
  );

  static PostExecuteVerification skipped(String reason) =>
      PostExecuteVerification._(
        status: PostExecuteStatus.skipped,
        reason: reason,
      );

  static PostExecuteVerification unverified({
    required String expectedEntity,
    required String entityType,
    required String reason,
  }) => PostExecuteVerification._(
    status: PostExecuteStatus.unverified,
    expectedEntity: expectedEntity,
    entityType: entityType,
    reason: reason,
  );
}

enum PostExecuteStatus { ok, unverified, skipped }

/// Generic anti-halu gate that runs AFTER a tool reports success.
///
/// Reads [ToolDefinition.verificationProbe] and verifies the expected
/// post-state actually exists in the ecosystem. Replaces the agent-only
/// `_verifyAgentRegistryCompletion` with a metadata-driven implementation
/// that works for any snapshot-backed entity (agent, workflow, provider,
/// module, ...).
///
/// Usage:
/// ```dart
/// final validator = PostExecuteValidator(snapshotBuilder: () async => ...);
/// final outcome = await validator.verify(
///   tool: tool,
///   definition: def,
///   result: result,
/// );
/// if (outcome.isUnverified) {
///   // trigger recovery flow
/// }
/// ```
class PostExecuteValidator {
  PostExecuteValidator({required this.snapshotBuilder});

  /// Builds a fresh ecosystem snapshot. The validator calls this AFTER the
  /// tool has executed so it observes the post-mutation state.
  final Future<EcosystemSnapshot> Function() snapshotBuilder;

  /// Run the verification probe configured on [definition], if any.
  Future<PostExecuteVerification> verify({
    required ToolCallRequest tool,
    required ToolDefinition definition,
    required ToolExecutionResult result,
  }) async {
    if (!result.success) {
      // Tool already declared failure — no need to verify, the runtime's
      // recovery flow will handle it. We return ok here to avoid stacking
      // an extra "unverified" message on top.
      return PostExecuteVerification.ok;
    }

    final probe = definition.verificationProbe;
    if (probe == null) return PostExecuteVerification.ok;
    if (probe.kind == 'none' || probe.kind.isEmpty) {
      return PostExecuteVerification.ok;
    }

    switch (probe.kind) {
      case 'snapshot_contains':
      case 'snapshot_absent':
        return _verifySnapshot(tool, definition, probe);
      case 'tool_result_data':
        return _verifyResultData(result, probe);
      default:
        return PostExecuteVerification.skipped(
          'unknown_probe_kind:${probe.kind}',
        );
    }
  }

  Future<PostExecuteVerification> _verifySnapshot(
    ToolCallRequest tool,
    ToolDefinition definition,
    ToolVerificationProbe probe,
  ) async {
    final selectorValue = _selectorValue(tool, definition, probe);
    if (selectorValue.isEmpty) {
      return PostExecuteVerification.skipped('no_selector_value');
    }

    final entityType = probe.entityType.isNotEmpty
        ? probe.entityType
        : definition.targetEntity;
    if (entityType.isEmpty) {
      return PostExecuteVerification.skipped('no_entity_type');
    }
    if (!SnapshotTargetResolver.isSnapshotBacked(entityType)) {
      return PostExecuteVerification.skipped('not_snapshot_backed:$entityType');
    }

    final EcosystemSnapshot snapshot;
    try {
      snapshot = await snapshotBuilder();
    } catch (e) {
      return PostExecuteVerification.skipped('snapshot_build_failed');
    }
    if (snapshot.isEmpty) {
      return PostExecuteVerification.skipped('snapshot_empty');
    }

    final match = SnapshotTargetResolver.resolve(
      snapshot: snapshot,
      entityType: entityType,
      // The probe gives us a single selector value. We don't know up-front
      // whether it's an id ("wf_976cb3ac") or a human label ("Daily Report").
      // The resolver already tries id-match first, then label, then fuzzy —
      // so we feed the same value to both slots and let it pick.
      entityId: selectorValue,
      entityLabel: selectorValue,
    );

    final present = match.isExact;
    final expectPresent = probe.expectPresent;

    if (present == expectPresent) {
      return PostExecuteVerification.ok;
    }

    return PostExecuteVerification.unverified(
      expectedEntity: selectorValue,
      entityType: entityType,
      reason: expectPresent
          ? 'expected_present_but_absent'
          : 'expected_absent_but_present',
    );
  }

  PostExecuteVerification _verifyResultData(
    ToolExecutionResult result,
    ToolVerificationProbe probe,
  ) {
    final data = result.data;
    if (data == null || data.isEmpty) {
      return PostExecuteVerification.unverified(
        expectedEntity: '',
        entityType: probe.entityType,
        reason: 'tool_result_data_empty',
      );
    }
    if (probe.expectedDataKeys.isEmpty) {
      // No keys declared — only the "non-empty data" check applies.
      return PostExecuteVerification.ok;
    }
    final missing = <String>[];
    for (final key in probe.expectedDataKeys) {
      final value = data[key];
      if (value == null) {
        missing.add(key);
        continue;
      }
      if (value is String && value.trim().isEmpty) {
        missing.add(key);
        continue;
      }
      if (value is Iterable && value.isEmpty) {
        missing.add(key);
        continue;
      }
      if (value is Map && value.isEmpty) {
        missing.add(key);
      }
    }
    if (missing.isEmpty) return PostExecuteVerification.ok;
    return PostExecuteVerification.unverified(
      expectedEntity: missing.join(', '),
      entityType: probe.entityType,
      reason: 'tool_result_missing_keys:${missing.join(",")}',
    );
  }

  /// Resolves the selector value used for snapshot lookup.
  /// Order:
  /// 1. probe.selectorArgKey
  /// 2. definition.selectorArgs (first non-empty value)
  /// 3. common keys: name, title, label
  String _selectorValue(
    ToolCallRequest tool,
    ToolDefinition definition,
    ToolVerificationProbe probe,
  ) {
    if (probe.selectorArgKey.isNotEmpty) {
      final raw = tool.args[probe.selectorArgKey];
      if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    }
    for (final key in definition.selectorArgs) {
      final raw = tool.args[key];
      if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    }
    for (final key in const ['name', 'title', 'label']) {
      final raw = tool.args[key];
      if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    }
    return '';
  }
}
