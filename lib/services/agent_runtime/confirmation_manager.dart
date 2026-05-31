import '../../features/providers/data/provider_config.dart';
import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'executor.dart';
import 'language_detector.dart';
import 'pending_action.dart';
import 'pending_clarification.dart';
import 'runtime_logger.dart';
import 'runtime_models.dart';
import 'task_ledger.dart';
import 'tool_verbalizer.dart';

/// Signature for the engine callback that executes a pending tool.
typedef ExecutePendingToolCallback = Future<AgentRuntimeResponse> Function({
  required AgentRuntimeRequest request,
  required PendingAction pending,
  required Executor executor,
  required ToolVerbalizer verbalizer,
  required DetectedLanguage detectedLang,
  required RuntimeLogger logger,
  required void Function(RuntimeEvent) emit,
});

/// Signature for the engine callback that finishes a task scope.
typedef FinishTaskScopeCallback = Future<void> Function(
  AgentRuntimeRequest request,
  LedgerStatus terminal,
);

/// Owns the mutable pending-action state and the confirmation decision flow.
///
/// Extracted from [AgentRuntimeEngine] as Phase 3 of the runtime decomposition.
/// Keeps the pending maps and the logic for restoring from ledger, handling
/// user decisions, and wiring up the confirmed-execution path.
class ConfirmationManager {
  ConfirmationManager({
    required TaskLedgerDatabase ledgerDb,
    required String languageCode,
    required ExecutePendingToolCallback onExecutePendingTool,
    required FinishTaskScopeCallback onFinishTaskScope,
    OpenAiCompatibleClient? llmClient,
  })  : _ledgerDb = ledgerDb,
        _languageCode = languageCode,
        _onExecutePendingTool = onExecutePendingTool,
        _onFinishTaskScope = onFinishTaskScope,
        _client = llmClient ?? OpenAiCompatibleClient();

  final TaskLedgerDatabase _ledgerDb;
  final String _languageCode;
  final ExecutePendingToolCallback _onExecutePendingTool;
  final FinishTaskScopeCallback _onFinishTaskScope;

  /// Shared LLM client for creating [Executor] and [ToolVerbalizer] inside
  /// [executeConfirmed].
  final OpenAiCompatibleClient _client;

  /// Pending actions per agent (agentId → PendingAction).
  final Map<String, PendingAction> _pendingActions = {};

  /// Pending clarification per agent.
  final Map<String, PendingClarification> _pendingClarifications = {};

  // ---------------------------------------------------------------------------
  // Public accessors
  // ---------------------------------------------------------------------------

  /// Get pending action for an agent.
  PendingAction? getPending(String agentId) => _pendingActions[agentId];

  /// Clear pending action for an agent.
  void clearPending(String agentId) => _pendingActions.remove(agentId);

  /// Clear pending clarification for an agent.
  void clearClarification(String agentId) =>
      _pendingClarifications.remove(agentId);

  /// Direct map access for engine methods that need to read/write the maps
  /// directly (e.g. checking containsKey, storing new entries, removing by
  /// agentId inline).
  Map<String, PendingAction> get pendingActions => _pendingActions;
  Map<String, PendingClarification> get pendingClarifications =>
      _pendingClarifications;

  // ---------------------------------------------------------------------------
  // Decision handling
  // ---------------------------------------------------------------------------

  /// Process a pending action decision (deterministic or LLM-classified).
  ///
  /// Returns an [AgentRuntimeResponse] for confirmed/rejected/preview decisions,
  /// or `null` when the decision is unclear/none (caller falls through to
  /// normal processing).
  Future<AgentRuntimeResponse?> handleDecision({
    required AgentRuntimeRequest request,
    required PendingAction pending,
    required ConfirmationDecision decision,
    required Executor executor,
    required ToolVerbalizer verbalizer,
    required DetectedLanguage detectedLang,
    required RuntimeLogger logger,
    required void Function(RuntimeEvent) emit,
  }) async {
    switch (decision) {
      case ConfirmationDecision.confirmed:
        _pendingActions.remove(request.agentId);
        return _onExecutePendingTool(
          request: request,
          pending: pending,
          executor: executor,
          verbalizer: verbalizer,
          detectedLang: detectedLang,
          logger: logger,
          emit: emit,
        );

      case ConfirmationDecision.rejected:
        await _onFinishTaskScope(request, LedgerStatus.aborted);
        logger.logStateChange(
          AgentRuntimeState.done,
          'User rejected pending action',
        );
        emit(logger.events.last);
        final cancelMsg = await verbalizer.cancel(
          tool: ToolCallRequest(
            name: pending.toolName,
            args: pending.toolArgs,
            risk: 'sensitive',
            requiresConfirmation: true,
          ),
          language: detectedLang,
        );
        return AgentRuntimeResponse(
          finalMessage: cancelMsg,
          success: true,
          state: AgentRuntimeState.done,
          events: logger.events,
        );

      case ConfirmationDecision.previewOnly:
        logger.logStateChange(
          AgentRuntimeState.done,
          'User requested preview only',
        );
        emit(logger.events.last);
        final previewMsg = pending.userFacingPreview.isNotEmpty
            ? pending.userFacingPreview
            : await verbalizer.preview(
                tool: ToolCallRequest(
                  name: pending.toolName,
                  args: pending.toolArgs,
                  risk: 'sensitive',
                  requiresConfirmation: true,
                ),
                language: detectedLang,
              );
        return AgentRuntimeResponse(
          finalMessage: previewMsg,
          success: true,
          state: AgentRuntimeState.done,
          events: logger.events,
        );

      case ConfirmationDecision.unclear:
      case ConfirmationDecision.none:
        return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Execute confirmed tool (after user approval via button)
  // ---------------------------------------------------------------------------

  /// Execute a tool the user confirmed via button tap.
  ///
  /// Creates a fresh [Executor] and [ToolVerbalizer], captures the prior
  /// pending state for resume context, then delegates to
  /// [_onExecutePendingTool].
  Future<AgentRuntimeResponse> executeConfirmed(
    AgentRuntimeRequest request, {
    required ProviderConfig provider,
    required String toolName,
    required Map<String, dynamic> toolArgs,
    void Function(RuntimeEvent event)? onEvent,
  }) async {
    final logger = RuntimeLogger();

    void emit(RuntimeEvent event) {
      onEvent?.call(event);
    }

    // Capture the pending action BEFORE clearing so we can use its
    // resumeContext to continue a multi-subgoal task.
    final priorPending = _pendingActions[request.agentId];
    _pendingActions.remove(request.agentId);

    final llmConfig = LlmProviderConfig(
      baseUrl: provider.baseUrl,
      apiKey: provider.apiKey,
      model: provider.model,
    );
    final executor = Executor(client: _client, config: llmConfig);

    // Confirmed-button taps don't carry a user message. Reuse the language
    // captured at the time the pending action was created (or fall back to
    // the engine's default).
    final detectedLang = priorPending != null
        ? DetectedLanguage(
            code: priorPending.languageCode,
            label: LanguageDetector.labelForCode(priorPending.languageCode),
            script: 'Latin',
            confidence: 0.5,
          )
        : DetectedLanguage(
            code: _languageCode,
            label: LanguageDetector.labelForCode(_languageCode),
            script: 'Latin',
            confidence: 0.4,
          );
    final verbalizer = ToolVerbalizer(client: _client, config: llmConfig);
    verbalizer.resetTurn();

    final pending = PendingAction(
      toolName: toolName,
      toolArgs: toolArgs,
      userFacingSummary: 'Confirmed by user',
      languageCode: detectedLang.code,
      resumeContext: priorPending?.resumeContext,
    );

    return _onExecutePendingTool(
      request: request,
      pending: pending,
      executor: executor,
      verbalizer: verbalizer,
      detectedLang: detectedLang,
      logger: logger,
      emit: emit,
    );
  }

  // ---------------------------------------------------------------------------
  // Ledger restore
  // ---------------------------------------------------------------------------

  /// Try to restore a pending action from a persisted ledger after app restart.
  ///
  /// Only fires when the ledger was last persisted at a confirmation gate
  /// (i.e. it has both [TaskLedger.pendingToolName] and
  /// [TaskLedger.pendingToolArgs]). Lossy/early-stage ledgers stay dormant
  /// and the next user turn will plan from scratch.
  Future<void> maybeRestoreFromLedger(String agentId) async {
    if (_pendingActions.containsKey(agentId)) return;
    final ledger = await _ledgerDb.findActive(
      agentId: agentId,
      source: LedgerSource.chat,
    );
    if (ledger == null) return;
    final toolName = ledger.pendingToolName;
    final toolArgs = ledger.pendingToolArgs;
    if (toolName == null || toolArgs == null) return;

    _pendingActions[agentId] = PendingAction(
      toolName: toolName,
      toolArgs: toolArgs,
      userFacingSummary: 'Resuming the task from where we left off.',
      languageCode: ledger.languageCode,
      resumeContext: {
        'ledger_id': ledger.id,
        'plan': ledger.plan ?? const {'steps': []},
        'goal_tree': ledger.goalTree.toJson(),
        'previous_results': ledger.previousResults,
        'current_step': ledger.currentStep,
        'available_tools': ledger.availableTools,
        'memory_snapshot': ledger.memorySnapshot,
        'auto_approve_sensitive': ledger.autoApproveSensitive,
        'is_workflow_auto_execute': ledger.isWorkflowAutoExecute,
        'language_code': ledger.languageCode,
        'language_label': LanguageDetector.labelForCode(ledger.languageCode),
        'language_script': 'Latin',
        'language_confidence': 0.6,
        'user_message': ledger.originalUserMessage,
      },
    );
  }
}