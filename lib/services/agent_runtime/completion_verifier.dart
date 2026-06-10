import '../../features/agents/data/agent_model.dart';
import 'ecosystem_snapshot.dart';
import 'goal_tree.dart';
import 'language_detector.dart';
import 'language_registry.dart';
import 'runtime_logger.dart';
import 'runtime_models.dart';

/// Verification result produced by [CompletionVerifier].
class CompletionVerification {
  const CompletionVerification({
    required this.ok,
    this.missingNames = const [],
    this.message = '',
    this.question = '',
  });

  final bool ok;
  final List<String> missingNames;
  final String message;
  final String question;
}

/// Post-completion state re-check that validates agent registry mutations
/// against the planned target graph before the engine declares a task done.
///
/// Near-pure — reads [agentLoader] from the engine, writes nothing.
/// Small, self-contained extraction from [AgentRuntimeEngine].
class CompletionVerifier {
  CompletionVerifier({
    required List<AgentModel> Function()? agentLoader,
    Future<EcosystemSnapshot> Function()? snapshotBuilder,
  }) : _agentLoader = agentLoader,
       _snapshotBuilder = snapshotBuilder;

  final List<AgentModel> Function()? _agentLoader;
  final Future<EcosystemSnapshot> Function()? _snapshotBuilder;

  /// Returns null if the completion is verified, or a blocker response with
  /// [AgentRuntimeState.askingUser] when the registry state is out of sync
  /// with the planned target graph.
  ///
  /// [parkTask] is a callback that persists the current task state for user
  /// input (delegates to the engine's `_parkTaskForUserInput`).
  Future<AgentRuntimeResponse?> blockIfUnverified({
    required AgentRuntimeRequest request,
    required Map<String, dynamic> plan,
    required GoalTree goalTree,
    required List<Map<String, dynamic>> previousResults,
    required int currentStep,
    required List<String> availableTools,
    required String memorySnapshot,
    required DetectedLanguage detectedLang,
    required bool autoApproveSensitive,
    required bool isWorkflowAutoExecute,
    required RuntimeLogger logger,
    required Future<void> Function(List<String> questions) parkTask,
    String? lastToolName,
  }) async {
    final verification = await _verify(
      plan: plan,
      goalTree: goalTree,
      previousResults: previousResults,
      lastToolName: lastToolName,
      language: detectedLang,
    );
    if (verification == null || verification.ok) return null;

    logger.logDivergence('verifier_blocked', {
      'missing': verification.missingNames,
      'last_tool': lastToolName ?? '',
    });

    for (final subgoal in goalTree.subgoals) {
      final expected = _expectedAgentNameForSubgoal(subgoal);
      if (expected != null &&
          verification.missingNames.any(
            (name) => name.toLowerCase() == expected.toLowerCase(),
          )) {
        subgoal.status = SubgoalStatus.inProgress;
        subgoal.notes = 'Verification failed: agent registry state mismatch.';
      }
    }

    await parkTask([verification.question]);
    logger.logFinalResponse(verification.message);
    return AgentRuntimeResponse(
      finalMessage: verification.message,
      success: false,
      state: AgentRuntimeState.askingUser,
      events: logger.events,
    );
  }

  Future<CompletionVerification?> _verify({
    required Map<String, dynamic> plan,
    required GoalTree goalTree,
    required List<Map<String, dynamic>> previousResults,
    required DetectedLanguage language,
    String? lastToolName,
  }) async {
    final targetGraph =
        (plan['runtime_target_graph'] as Map?)?.cast<String, dynamic>() ??
        const {};
    final graphTargets =
        (targetGraph['targets'] as List?)
            ?.whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    final touchedConfigPatch =
        lastToolName == 'system.config.patch' ||
        previousResults.any((r) => r['tool'] == 'system.config.patch');
    final hasAgentCreateTarget = graphTargets.any(
      (target) =>
          target['entity_type'] == 'agent' &&
          target['operation'] == 'create' &&
          target['status'] != 'skipped',
    );
    final hasAgentDeleteTarget = graphTargets.any(
      (target) =>
          target['entity_type'] == 'agent' &&
          target['operation'] == 'delete' &&
          target['status'] == 'eligible',
    );
    final touchedAgentCreate = touchedConfigPatch && hasAgentCreateTarget;
    final touchedAgentDelete = touchedConfigPatch && hasAgentDeleteTarget;
    if (touchedConfigPatch) {
      final configVerification = await _verifySnapshotTargets(
        graphTargets,
        language,
      );
      if (configVerification != null && !configVerification.ok) {
        return configVerification;
      }
    }
    if ((!touchedAgentCreate && !touchedAgentDelete) || goalTree.isEmpty) {
      return null;
    }

    final loadAgents = _agentLoader;
    if (loadAgents == null) return null;
    final existing = loadAgents()
        .map((a) => a.name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
    if (existing.isEmpty && !touchedAgentCreate) return null;

    final expectedCreates = graphTargets
        .where(
          (target) =>
              target['entity_type'] == 'agent' &&
              target['operation'] == 'create' &&
              target['status'] != 'skipped',
        )
        .map((target) => (target['entity_label'] ?? '').toString().trim())
        .where((name) => name.isNotEmpty)
        .toSet();
    final expectedDeletes = graphTargets
        .where(
          (target) =>
              target['entity_type'] == 'agent' &&
              target['operation'] == 'delete' &&
              target['status'] == 'eligible',
        )
        .map((target) => (target['entity_label'] ?? '').toString().trim())
        .where((name) => name.isNotEmpty)
        .toSet();

    final expectedFromTree = goalTree.subgoals
        .map(_expectedAgentNameForSubgoal)
        .whereType<String>()
        .where((name) => name.trim().isNotEmpty)
        .toSet();
    if (touchedAgentCreate && expectedCreates.isEmpty) {
      expectedCreates.addAll(expectedFromTree);
    }
    if (expectedCreates.isEmpty && expectedDeletes.isEmpty) return null;

    final missingCreates = expectedCreates
        .where((name) => !existing.contains(name.toLowerCase()))
        .toList(growable: false);
    final stillPresentDeletes = expectedDeletes
        .where((name) => existing.contains(name.toLowerCase()))
        .toList(growable: false);
    if (missingCreates.isEmpty && stillPresentDeletes.isEmpty) {
      return const CompletionVerification(ok: true);
    }

    final actuallyMissing = missingCreates;
    final actuallyStillPresent = stillPresentDeletes;
    if (actuallyMissing.isEmpty && actuallyStillPresent.isEmpty) {
      return const CompletionVerification(ok: true);
    }

    final mismatchNames = [...actuallyMissing, ...actuallyStillPresent];
    final entityList = mismatchNames.join(', ');
    final message = LanguageRegistry.phrase(
      'completion_unverified',
      language.code,
      {'entity': entityList.isEmpty ? 'agen yang diminta' : entityList},
    );
    return CompletionVerification(
      ok: false,
      missingNames: mismatchNames,
      message: message,
      question: message,
    );
  }

  Future<CompletionVerification?> _verifySnapshotTargets(
    List<Map<String, dynamic>> graphTargets,
    DetectedLanguage language,
  ) async {
    final needsSnapshot = graphTargets.any(
      (target) =>
          (target['entity_type'] == 'provider' ||
              target['entity_type'] == 'module') &&
          (target['operation'] == 'create' ||
              target['operation'] == 'update' ||
              target['operation'] == 'delete'),
    );
    if (!needsSnapshot) return null;
    final build = _snapshotBuilder;
    if (build == null) return null;
    final snapshot = await build();
    final providerNames = snapshot.providers
        .expand((p) => [p.id, p.nickname])
        .map((v) => v.trim().toLowerCase())
        .where((v) => v.isNotEmpty)
        .toSet();
    final moduleIds = snapshot.modules
        .map((m) => m.id.trim().toLowerCase())
        .where((v) => v.isNotEmpty)
        .toSet();
    final mismatches = <String>[];
    for (final target in graphTargets) {
      final type = (target['entity_type'] ?? '').toString();
      if (type != 'provider' && type != 'module') continue;
      final op = (target['operation'] ?? '').toString();
      final label = (target['entity_label'] ?? '').toString().trim();
      if (label.isEmpty) continue;
      final present = type == 'provider'
          ? providerNames.contains(label.toLowerCase())
          : moduleIds.contains(label.toLowerCase());
      if ((op == 'create' || op == 'update') && !present) {
        mismatches.add(label);
      } else if (op == 'delete' && present) {
        mismatches.add(label);
      }
    }
    if (mismatches.isEmpty) return const CompletionVerification(ok: true);
    final entityList = mismatches.join(', ');
    final message = LanguageRegistry.phrase(
      'completion_unverified',
      language.code,
      {'entity': entityList},
    );
    return CompletionVerification(
      ok: false,
      missingNames: mismatches,
      message: message,
      question: message,
    );
  }

  String? _expectedAgentNameForSubgoal(Subgoal subgoal) {
    for (final key in const [
      'name',
      'agentName',
      'agent_name',
      'targetName',
      'target_name',
    ]) {
      final value = subgoal.requiredSlots[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }

    final quoted = RegExp(
      r'[""]([^""]+)[""]',
    ).firstMatch(subgoal.label)?.group(1)?.trim();
    if (quoted != null && quoted.isNotEmpty) return quoted;

    final match = RegExp(
      r'\b(?:agent|agen)\s+([A-Za-z0-9_-]{2,})\b',
      caseSensitive: false,
    ).firstMatch(subgoal.label);
    return match?.group(1)?.trim();
  }
}
