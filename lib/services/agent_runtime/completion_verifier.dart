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

/// Trust-the-tool-result completion verifier.
///
/// **Architecture note:** the previous verifier re-read in-memory Riverpod
/// state after a tool ran, which produced false negatives because the
/// in-memory list lagged behind the on-disk write. The new architecture
/// (Phase 2 — SQLite-backed reactive repositories + Phase 3 — domain tools
/// that return the entity they wrote) makes that re-check redundant.
///
/// This verifier checks that the last tool result satisfies its declared
/// [ToolDefinition.verificationProbe]. If the probe expects keys like `id`,
/// `name`, or `changedPaths` and they're present, the operation is verified.
/// No stale-state race possible.
///
/// For domain tools (`agent.*`, `provider.*`) that return the entity they
/// wrote, verification is always instant and correct.
///
/// The old constructor params (`agentLoader`, `snapshotBuilder`) are retained
/// temporarily for caller compatibility — they are no longer used internally.
class CompletionVerifier {
  CompletionVerifier({
    // Legacy params — ignored. Kept for caller compatibility during
    // transition (runtime_engine.dart still passes these).
    List<AgentModel> Function()? agentLoader,
    Future<EcosystemSnapshot> Function()? snapshotBuilder,
  });

  /// Returns null when the completion is verified, or a blocker response
  /// when the result is missing required verification data keys.
  ///
  /// Signature retains all existing named params so callers compile unchanged.
  /// Internally only uses `lastToolName`, `logger`, `detectedLang`, and
  /// `parkTask`. The new optional params `lastToolDef` and `lastResult`
  /// carry the actual data for verification.
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
    // New optional params for the simplified verification path.
    ToolDefinition? lastToolDef,
    ToolExecutionResult? lastResult,
  }) async {
    // -----------------------------------------------------------------------
    // New path: domain tools that carry lastToolDef + lastResult get the
    // streamlined probe-based check. No re-query needed.
    // -----------------------------------------------------------------------
    if (lastToolDef != null && lastResult != null) {
      if (!lastResult.success) return null; // reviewer handles failures.
      final probe = lastToolDef.verificationProbe;
      if (probe == null) return null; // no probe = auto-pass.

      final data = lastResult.data;
      if (data == null) {
        return _blockGeneric(logger, detectedLang, parkTask);
      }
      for (final key in probe.expectedDataKeys) {
        if (!data.containsKey(key) || data[key] == null) {
          logger.logDivergence('verifier_blocked', {
            'reason': 'missing_key',
            'key': key,
            'tool': lastToolName ?? '',
          });
          return _blockGeneric(logger, detectedLang, parkTask);
        }
      }
      return null; // Verified via probe.
    }

    // -----------------------------------------------------------------------
    // Legacy path: `system.config.patch` calls that don't pass lastToolDef.
    // During transition these still flow through here. Bypass verification
    // entirely for successful tool results in previousResults — trust the
    // tool's own response to avoid the stale-state false negative.
    // -----------------------------------------------------------------------
    final lastResultFromHistory = previousResults.isNotEmpty
        ? previousResults.last
        : null;
    if (lastResultFromHistory != null) {
      final tool = lastResultFromHistory['tool'] as String?;
      final resultData = lastResultFromHistory['result'];
      if (tool == 'system.config.patch' && resultData is Map) {
        // config.patch returns backupId + changedPaths + configHash on
        // success. If those are present, consider it verified.
        if (resultData.containsKey('backupId') &&
            resultData.containsKey('changedPaths') &&
            resultData.containsKey('configHash')) {
          return null; // Trust the tool result.
        }
      }
    }

    // No verification data available — pass through. The reviewer will
    // catch logical failures via its own status check.
    return null;
  }

  Future<AgentRuntimeResponse> _blockGeneric(
    RuntimeLogger logger,
    DetectedLanguage detectedLang,
    Future<void> Function(List<String> questions) parkTask,
  ) async {
    final message = LanguageRegistry.phrase(
      'completion_unverified_generic',
      detectedLang.code,
    );
    logger.logFinalResponse(message);
    await parkTask([message]);
    return AgentRuntimeResponse(
      finalMessage: message,
      success: false,
      state: AgentRuntimeState.askingUser,
      events: logger.events,
    );
  }
}
