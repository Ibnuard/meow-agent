import 'confirmation_manager.dart';
import 'goal_tree.dart';
import 'pending_clarification.dart';
import 'runtime_models.dart';
import 'task_ledger.dart';

/// Owns the ledger lifecycle and cancellation state for agent task scopes.
///
/// Extracted from [AgentRuntimeEngine] as Phase 4 of the runtime decomposition.
/// Manages:
/// - Cooperative cancellation flags (`_cancelledAgents`)
/// - Ledger persistence at confirmation gates (`persistLedgerAtGate`)
/// - Task parking for user input (`parkForUserInput`)
/// - Task scope finish/archive lifecycle (`finishScope`, `archiveLedgerForRequest`)
class TaskScopeManager {
  TaskScopeManager({
    required this.ledgerDb,
  });

  /// Persistent ledger store for multi-step tasks.
  final TaskLedgerDatabase ledgerDb;

  /// Set after [ConfirmationManager] is created to break the circular init:
  /// TaskScopeManager ↔ ConfirmationManager.onFinishTaskScope.
  ConfirmationManager? _confirmation;

  /// Attach the [ConfirmationManager] after both objects exist.
  void attachConfirmation(ConfirmationManager c) => _confirmation = c;

  final Set<String> _cancelledAgents = {};

  // ---------------------------------------------------------------------------
  // Cancellation
  // ---------------------------------------------------------------------------

  /// Mark an agent as cancelled so [_executeLoop] bails out cooperatively.
  void cancel(String agentId) => _cancelledAgents.add(agentId);

  /// Remove the cancellation flag for an agent (when starting a new task).
  void clearCancellation(String agentId) => _cancelledAgents.remove(agentId);

  /// Whether the agent's current task has been cancelled.
  bool isCancelled(String agentId) => _cancelledAgents.contains(agentId);

  /// Abort the current chat task scope for an agent.
  ///
  /// Used by the UI reject path: clearing the visible confirmation is not
  /// enough, because a persisted ledger can otherwise rehydrate the same
  /// pending tool on the next user turn.
  Future<void> abortActive(
    String agentId, {
    RequestSource source = RequestSource.chat,
  }) async {
    cancel(agentId);
    await finishScope(
      agentId: agentId,
      source: source,
      terminal: LedgerStatus.aborted,
    );
  }

  // ---------------------------------------------------------------------------
  // Scope lifecycle
  // ---------------------------------------------------------------------------

  /// Shorthand that pulls [agentId] and [source] from the request.
  Future<void> finishScopeForRequest(
    AgentRuntimeRequest request,
    LedgerStatus terminal,
  ) {
    return finishScope(
      agentId: request.agentId,
      source: request.source,
      terminal: terminal,
    );
  }

  /// Finish a task scope: clear pending state and archive/delete the ledger.
  Future<void> finishScope({
    required String agentId,
    required RequestSource source,
    required LedgerStatus terminal,
  }) async {
    _confirmation?.pendingActions.remove(agentId);
    _confirmation?.pendingClarifications.remove(agentId);

    // Workflow run state lives in the WorkflowRunner's run ledger, not here.
    if (source == RequestSource.workflow) return;

    final active = await ledgerDb.findActive(
      agentId: agentId,
      source: _ledgerSourceFor(source),
    );
    if (active == null) return;
    if (terminal == LedgerStatus.failed) {
      await ledgerDb.delete(active.id);
    } else {
      await ledgerDb.archive(active.id, terminal);
    }
  }

  /// Archive a ledger as completed when the goal tree finishes successfully.
  /// No-op when no ledger exists for the (agentId, source) scope.
  Future<void> archiveLedgerForRequest(
    AgentRuntimeRequest request,
    LedgerStatus terminal,
  ) async {
    // Workflow runs do not use the engine's resume ledger.
    if (request.source == RequestSource.workflow) return;
    final active = await ledgerDb.findActive(
      agentId: request.agentId,
      source: _ledgerSourceFor(request.source),
    );
    if (active == null) return;
    if (terminal == LedgerStatus.failed) {
      // Soft-delete failed ledgers so retry isn't polluted by stale state.
      await ledgerDb.delete(active.id);
    } else {
      await ledgerDb.archive(active.id, terminal);
    }
  }

  // ---------------------------------------------------------------------------
  // Ledger persistence at confirmation gates
  // ---------------------------------------------------------------------------

  /// Persist the current task state to the ledger at a confirmation gate.
  ///
  /// The ledger becomes the authoritative store for the task — `resumeContext`
  /// only needs to carry a pointer (`ledger_id`) afterwards.
  Future<TaskLedger> persistLedgerAtGate({
    required AgentRuntimeRequest request,
    required Map<String, dynamic> plan,
    required GoalTree goalTree,
    required List<Map<String, dynamic>> previousResults,
    required int currentStep,
    required List<String> availableTools,
    required String memorySnapshot,
    required String detectedLangCode,
    required bool autoApproveSensitive,
    required bool isWorkflowAutoExecute,
    ToolCallRequest? pendingTool,
  }) async {
    final source = request.source == RequestSource.workflow
        ? LedgerSource.workflow
        : LedgerSource.chat;

    final existing = await ledgerDb.findActive(
      agentId: request.agentId,
      source: source,
    );

    if (existing != null) {
      // Update in place — the loop is mid-flight, just sync state.
      existing.goalTree = goalTree;
      existing.previousResults = List.of(previousResults);
      existing.currentStep = currentStep;
      existing.plan = plan;
      existing.targetGraph =
          (plan['runtime_target_graph'] as Map?)?.cast<String, dynamic>() ??
          existing.targetGraph;
      existing.pendingToolName = pendingTool?.name;
      existing.pendingToolArgs = pendingTool?.args;
      return ledgerDb.upsert(existing);
    }

    final ledger = TaskLedger(
      id:
          'lg_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          '_${request.agentId.hashCode.toUnsigned(16).toRadixString(16)}',
      agentId: request.agentId,
      source: source,
      sourceRef: source == LedgerSource.workflow ? request.userMessage : null,
      mainGoal: goalTree.mainGoal,
      languageCode: detectedLangCode,
      originalUserMessage: request.userMessage,
      goalTree: goalTree,
      completionCriteria: goalTree.completionCriteria,
      previousResults: List.of(previousResults),
      targetGraph:
          (plan['runtime_target_graph'] as Map?)?.cast<String, dynamic>() ??
          const {},
      currentStep: currentStep,
      availableTools: availableTools,
      memorySnapshot: memorySnapshot,
      autoApproveSensitive: autoApproveSensitive,
      isWorkflowAutoExecute: isWorkflowAutoExecute,
      plan: plan,
      pendingToolName: pendingTool?.name,
      pendingToolArgs: pendingTool?.args,
    );
    return ledgerDb.upsert(ledger);
  }

  // ---------------------------------------------------------------------------
  // Park task for user input (clarification / question)
  // ---------------------------------------------------------------------------

  /// Park the current task state so it can be resumed after the user answers.
  ///
  /// Stores a [PendingClarification] in [ConfirmationManager] and persists the
  /// ledger (when the goal tree has meaningful progress).
  Future<void> parkForUserInput({
    required AgentRuntimeRequest request,
    required Map<String, dynamic> plan,
    required GoalTree goalTree,
    required List<Map<String, dynamic>> previousResults,
    required int currentStep,
    required List<String> availableTools,
    required String memorySnapshot,
    required String detectedLangCode,
    required bool autoApproveSensitive,
    required bool isWorkflowAutoExecute,
    required List<String> questions,
  }) async {
    final cleanQuestions = questions
        .map((q) => q.trim())
        .where((q) => q.isNotEmpty)
        .toList(growable: false);
    if (cleanQuestions.isEmpty) return;

    _confirmation?.pendingClarifications[request.agentId] = PendingClarification(
      originalMessage: request.userMessage,
      questions: cleanQuestions,
      createdAt: DateTime.now(),
    );

    if (goalTree.isNotEmpty && !goalTree.isComplete) {
      await persistLedgerAtGate(
        request: request,
        plan: plan,
        goalTree: goalTree,
        previousResults: previousResults,
        currentStep: currentStep,
        availableTools: availableTools,
        memorySnapshot: memorySnapshot,
        detectedLangCode: detectedLangCode,
        autoApproveSensitive: autoApproveSensitive,
        isWorkflowAutoExecute: isWorkflowAutoExecute,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  LedgerSource _ledgerSourceFor(RequestSource source) =>
      source == RequestSource.workflow
          ? LedgerSource.workflow
          : LedgerSource.chat;
}
