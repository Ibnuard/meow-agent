import '../../features/agents/data/agent_model.dart';
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
  }) : _agentLoader = agentLoader;

  final List<AgentModel> Function()? _agentLoader;

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
    final verification = _verify(
      plan: plan,
      goalTree: goalTree,
      previousResults: previousResults,
      lastToolName: lastToolName,
      language: detectedLang,
    );
    if (verification == null || verification.ok) return null;

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

  CompletionVerification? _verify({
    required Map<String, dynamic> plan,
    required GoalTree goalTree,
    required List<Map<String, dynamic>> previousResults,
    required DetectedLanguage language,
    String? lastToolName,
  }) {
    final touchedAgentCreate =
        lastToolName == 'system.agents.create' ||
        previousResults.any((r) => r['tool'] == 'system.agents.create');
    final touchedAgentDelete =
        lastToolName == 'system.agents.delete' ||
        previousResults.any((r) => r['tool'] == 'system.agents.delete');
    if ((!touchedAgentCreate && !touchedAgentDelete) || goalTree.isEmpty) {
      return null;
    }

    final loadAgents = _agentLoader;
    if (loadAgents == null) return null;
    final existing = loadAgents()
        .map((a) => a.name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
    if (existing.isEmpty) return null;

    final targetGraph =
        (plan['runtime_target_graph'] as Map?)?.cast<String, dynamic>() ??
        const {};
    final graphTargets =
        (targetGraph['targets'] as List?)
            ?.whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];

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

    // Cross-check missing creates against the authoritative tool result.
    // The agent provider snapshot may be one frame behind the underlying
    // repository write (Riverpod state propagation), but if the tool itself
    // returned success for the exact name we expect, the create did happen.
    // Trust the tool result as the source of truth in that case.
    final toolConfirmedCreates = <String>{};
    for (final r in previousResults) {
      if (r['tool'] != 'system.agents.create') continue;
      if (r['success'] != true) continue;
      final data = r['data'];
      if (data is! Map) continue;
      final agent = data['agent'];
      if (agent is! Map) continue;
      final createdName = (agent['name'] ?? '').toString().trim().toLowerCase();
      if (createdName.isNotEmpty) toolConfirmedCreates.add(createdName);
    }
    final actuallyMissing = missingCreates
        .where((name) => !toolConfirmedCreates.contains(name.toLowerCase()))
        .toList(growable: false);
    if (actuallyMissing.isEmpty && stillPresentDeletes.isEmpty) {
      return const CompletionVerification(ok: true);
    }

    final mismatchNames = [...actuallyMissing, ...stillPresentDeletes];
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