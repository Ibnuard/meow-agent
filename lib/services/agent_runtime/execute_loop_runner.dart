import 'completion_verifier.dart';
import 'executor.dart';
import 'goal_tree.dart';
import 'language_detector.dart';
import 'language_registry.dart';
import 'runtime_models.dart';
import 'task_ledger.dart';
import 'pending_action.dart';
import 'post_execute_validator.dart';
import 'preflight_checker.dart';
import 'recovery_coordinator.dart';
import 'runtime_logger.dart';
import 'runtime_memory.dart';
import 'task_scope_manager.dart';
import 'tool_permission_policy.dart';
import 'tool_router.dart';
import 'tool_verbalizer.dart';
import 'workspace_loader.dart';

/// Runs the main tool-execution loop for the agentic runtime.
///
/// Extracted from [AgentRuntimeEngine] as Phase 5 of the runtime decomposition.
/// Owns the 1,133-line `_executeLoop`, `_maybeRecover`, `_summarizeArgs`, and
/// ~12 helper methods. Depends on six injected services; all per-call data is
/// threaded through `run()` parameters.
class ExecuteLoopRunner {
  ExecuteLoopRunner({
    required ToolRouter toolRouter,
    required WorkspaceLoader workspaceLoader,
    required TaskScopeManager taskScope,
    required PreflightChecker preflight,
    required CompletionVerifier completionVerifier,
    required RuntimeMemory memory,
    required String languageCode,
  })  : _toolRouter = toolRouter,
        _workspaceLoader = workspaceLoader,
        _taskScope = taskScope,
        _preflight = preflight,
        _completionVerifier = completionVerifier,
        _memory = memory,
        _languageCode = languageCode;

  final ToolRouter _toolRouter;
  final WorkspaceLoader _workspaceLoader;
  final TaskScopeManager _taskScope;
  final PreflightChecker _preflight;
  final CompletionVerifier _completionVerifier;
  final RuntimeMemory _memory;
  final String _languageCode;

  static const int maxSteps = 5;

  // ---------------------------------------------------------------------------
  // Main loop (was _executeLoop)
  // ---------------------------------------------------------------------------

  Future<AgentRuntimeResponse> run({
    required AgentRuntimeRequest request,
    required Map<String, dynamic> plan,
    required GoalTree goalTree,
    required Executor executor,
    required ToolVerbalizer verbalizer,
    required DetectedLanguage detectedLang,
    required List<String> availableTools,
    required RuntimeLogger logger,
    required void Function(RuntimeEvent) emit,
    required String memorySnapshot,
    RecoveryCoordinator? recovery,
    PostExecuteValidator? postExecuteValidator,
    Future<({Map<String, dynamic> plan, GoalTree goalTree})?> Function()?
    rethink,
    bool autoApproveSensitive = false,
    bool isWorkflowAutoExecute = false,
    List<Map<String, dynamic>>? initialPreviousResults,
    int initialStep = 1,
    int nullSelectionRecoveryCount = 0,
  }) async {
    final previousResults = <Map<String, dynamic>>[...?initialPreviousResults];
    var currentStep = initialStep;
    var retryCount = 0;
    var rePlanned = false;
    final stuck = StuckDetector();

    // Idempotency tracking for delivery/side-effect tools.
    final deliveredKeys = <String>{};
    ToolCallRequest? lastDeliveryTool;
    ToolExecutionResult? lastDeliveryResult;

    // Conversation history snapshot (latest 20, chronological).
    final loopRecentMsgs = () {
      final src = request.recentMessages;
      final latest = src.length > 20 ? src.sublist(src.length - 20) : src;
      return latest.map((m) => {'role': m.role, 'content': m.content}).toList();
    }();

    // Adaptive budget: base + 2 steps per subgoal, hard-capped at maxSteps×3.
    final adaptiveLimit = goalTree.isEmpty
        ? maxSteps
        : (maxSteps + goalTree.subgoals.length * 2).clamp(
            maxSteps,
            maxSteps * 3,
          );

    for (var i = 0; i < adaptiveLimit; i++) {
      // Cooperative cancellation check.
      if (_taskScope.isCancelled(request.agentId)) {
        _taskScope.clearCancellation(request.agentId);
        return AgentRuntimeResponse(
          finalMessage: '',
          success: false,
          state: AgentRuntimeState.failed,
        );
      }

      var state = AgentRuntimeState.selectingTool;
      logger.logStateChange(state, 'Selecting tool (step $currentStep)');
      emit(logger.events.last);

      final selection = await executor.selectTool(
        plan: plan,
        currentStep: currentStep,
        previousResults: previousResults,
        availableTools: availableTools,
        logger: logger,
        recentToolMemory: memorySnapshot,
        isWorkflowAutoExecute: isWorkflowAutoExecute,
        goalTree: goalTree,
        recentMessages: loopRecentMsgs,
      );
      emit(logger.events.last);

      if (selection == null) {
        if (nullSelectionRecoveryCount >= 1) {
          logger.logNarrative(
            'recovery',
            'Repeated null tool selection. Aborting to prevent infinite loop.',
          );
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          return fail(_capabilityNotFoundMessage(detectedLang), logger);
        }
        final recoveryDecision = await _maybeRecover(
          recovery: recovery,
          rethink: rethink,
          reason: 'selector_null',
          stageHint: 'select_tool',
          logger: logger,
        );
        if (recoveryDecision != null) {
          return run(
            request: request,
            plan: recoveryDecision.plan,
            goalTree: recoveryDecision.goalTree,
            executor: executor,
            verbalizer: verbalizer,
            detectedLang: detectedLang,
            availableTools: availableTools,
            logger: logger,
            emit: emit,
            memorySnapshot: memorySnapshot,
            recovery: recovery,
            postExecuteValidator: postExecuteValidator,
            rethink: rethink,
            autoApproveSensitive: autoApproveSensitive,
            isWorkflowAutoExecute: isWorkflowAutoExecute,
            nullSelectionRecoveryCount: nullSelectionRecoveryCount + 1,
          );
        }
        await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
        return fail(
          recovery?.giveUpMessage(detectedLang) ??
              _capabilityNotFoundMessage(detectedLang),
          logger,
        );
      }

      final selectNarrative = (selection['narrative'] ?? '').toString();
      if (selectNarrative.isNotEmpty) {
        logger.logNarrative('select_tool', selectNarrative);
        emit(logger.events.last);
      }

      final status = selection['status'] as String? ?? '';

      if (status == 'done') {
        final finalResponse =
            selection['final_response'] as String? ?? 'Task completed.';
        if (goalTree.isNotEmpty && !goalTree.isComplete) {
          final active = goalTree.nextActionable;
          if (active != null && _isAnswerOnlySubgoal(active)) {
            active.status = SubgoalStatus.done;
            active.notes = 'answered_user';
          }
        }
        if (goalTree.isNotEmpty && !goalTree.isComplete) {
          logger.logError(
            'Selector tried to finish early but goal tree is incomplete '
            '(${goalTree.subgoals.where((s) => !s.isTerminal).length} subgoals remaining). Continuing loop.',
          );
          previousResults.add({
            'step': currentStep,
            'note':
                'Selector returned status=done but subgoals remain. Forcing continue.',
          });
          currentStep++;
          continue;
        }

        final verificationBlocker = await _completionVerifier.blockIfUnverified(
          request: request,
          plan: plan,
          goalTree: goalTree,
          previousResults: previousResults,
          currentStep: currentStep,
          availableTools: availableTools,
          memorySnapshot: memorySnapshot,
          detectedLang: detectedLang,
          autoApproveSensitive: autoApproveSensitive,
          isWorkflowAutoExecute: isWorkflowAutoExecute,
          logger: logger,
          parkTask: (questions) => _taskScope.parkForUserInput(
            request: request,
            plan: plan,
            goalTree: goalTree,
            previousResults: previousResults,
            currentStep: currentStep,
            availableTools: availableTools,
            memorySnapshot: memorySnapshot,
            detectedLangCode: detectedLang.code,
            autoApproveSensitive: autoApproveSensitive,
            isWorkflowAutoExecute: isWorkflowAutoExecute,
            questions: questions,
          ),
          lastToolName: previousResults.isEmpty
              ? null
              : previousResults.last['tool'] as String?,
        );
        if (verificationBlocker != null) return verificationBlocker;

        logger.logFinalResponse(finalResponse);
        await _workspaceLoader.updateHeartbeat(
          request.agentName.isNotEmpty ? request.agentName : request.agentId,
          state: 'done',
          task: request.userMessage,
          lastResult: 'success',
        );
        return AgentRuntimeResponse(
          finalMessage: finalResponse,
          success: true,
          state: AgentRuntimeState.done,
          events: logger.events,
        );
      }

      if (status == 'ask_user') {
        return AgentRuntimeResponse(
          finalMessage:
              selection['question'] as String? ?? 'Need more information.',
          success: true,
          state: AgentRuntimeState.askingUser,
          events: logger.events,
        );
      }

      if (status == 'failed') {
        final recoveryDecision = await _maybeRecover(
          recovery: recovery,
          rethink: rethink,
          reason: 'selector_failed',
          stageHint: 'select_tool',
          errorSummary: selection['error']?.toString() ?? '',
          logger: logger,
        );
        if (recoveryDecision != null) {
          return run(
            request: request,
            plan: recoveryDecision.plan,
            goalTree: recoveryDecision.goalTree,
            executor: executor,
            verbalizer: verbalizer,
            detectedLang: detectedLang,
            availableTools: availableTools,
            logger: logger,
            emit: emit,
            memorySnapshot: memorySnapshot,
            recovery: recovery,
            postExecuteValidator: postExecuteValidator,
            rethink: rethink,
            autoApproveSensitive: autoApproveSensitive,
            isWorkflowAutoExecute: isWorkflowAutoExecute,
          );
        }
        await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
        return fail(
          recovery?.giveUpMessage(detectedLang) ??
              (selection['error'] as String? ?? 'Runtime failed.'),
          logger,
        );
      }

      if (status == 'tool_required') {
        final toolJson = selection['tool'] as Map<String, dynamic>?;
        if (toolJson == null) {
          final recoveryDecision = await _maybeRecover(
            recovery: recovery,
            rethink: rethink,
            reason: 'selector_missing_tool',
            stageHint: 'select_tool',
            logger: logger,
          );
          if (recoveryDecision != null) {
            return run(
              request: request,
              plan: recoveryDecision.plan,
              goalTree: recoveryDecision.goalTree,
              executor: executor,
              verbalizer: verbalizer,
              detectedLang: detectedLang,
              availableTools: availableTools,
              logger: logger,
              emit: emit,
              memorySnapshot: memorySnapshot,
              recovery: recovery,
              postExecuteValidator: postExecuteValidator,
              rethink: rethink,
              autoApproveSensitive: autoApproveSensitive,
              isWorkflowAutoExecute: isWorkflowAutoExecute,
            );
          }
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          return fail(
            recovery?.giveUpMessage(detectedLang) ??
                'Tool selection returned no tool data.',
            logger,
          );
        }

        final toolRequest = ToolCallRequest.fromJson(toolJson);

        // Stuck detection.
        if (stuck.observe(toolName: toolRequest.name, args: toolRequest.args)) {
          if (!rePlanned) {
            rePlanned = true;
            stuck.reset();
            logger.logError(
              'Stuck loop detected (same call ×3). Forcing one re-plan.',
            );
            previousResults.add({
              'step': currentStep,
              'note':
                  'Detected stuck loop on ${toolRequest.name}. Reconsider approach for active subgoal.',
            });
            currentStep++;
            continue;
          }
          final recoveryDecision = await _maybeRecover(
            recovery: recovery,
            rethink: rethink,
            failedTool: toolRequest,
            reason: 'stuck_loop',
            logger: logger,
          );
          if (recoveryDecision != null) {
            stuck.reset();
            rePlanned = false;
            return run(
              request: request,
              plan: recoveryDecision.plan,
              goalTree: recoveryDecision.goalTree,
              executor: executor,
              verbalizer: verbalizer,
              detectedLang: detectedLang,
              availableTools: availableTools,
              logger: logger,
              emit: emit,
              memorySnapshot: memorySnapshot,
              recovery: recovery,
              postExecuteValidator: postExecuteValidator,
              rethink: rethink,
              autoApproveSensitive: autoApproveSensitive,
              isWorkflowAutoExecute: isWorkflowAutoExecute,
            );
          }
          final abortMsg =
              recovery?.giveUpMessage(detectedLang) ??
              await verbalizer.abort(
                reason: 'agent looped on ${toolRequest.name} after retry',
                language: detectedLang,
              );
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          logger.logFinalResponse(abortMsg);
          return AgentRuntimeResponse(
            finalMessage: abortMsg,
            success: false,
            state: AgentRuntimeState.failed,
            events: logger.events,
          );
        }

        final validationError = _toolRouter.validate(toolRequest);
        if (validationError != null) {
          logger.logError(validationError);
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          return fail(_capabilityNotFoundMessage(detectedLang), logger);
        }

        final definition = _toolRouter.getDefinition(toolRequest.name)!;

        final permissionDenied = await _toolRouter.permissionDeniedResult(
          toolRequest.name,
        );
        if (permissionDenied != null) {
          logger.logToolResult(permissionDenied);
          emit(logger.events.last);
          _memory.record(
            agentId: request.agentId,
            toolName: toolRequest.name,
            args: toolRequest.args,
            data: permissionDenied.data,
            success: false,
            error: permissionDenied.error,
          );
          await _workspaceLoader.updateHeartbeat(
            request.agentName.isNotEmpty ? request.agentName : request.agentId,
            state: AgentRuntimeState.failed.name,
            task: request.userMessage,
            lastTool: toolRequest.name,
            lastResult: 'permission_denied',
            lastError: permissionDenied.error,
          );
          final finalResponse =
              permissionDeniedResponseFor(permissionDenied) ??
              (permissionDenied.error ?? 'Permission denied.');
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          logger.logFinalResponse(finalResponse);
          return AgentRuntimeResponse(
            finalMessage: finalResponse,
            success: false,
            state: AgentRuntimeState.failed,
            events: logger.events,
          );
        }

        // Pre-flight typo/existence check.
        final preflight = await _preflight.check(
          tool: toolRequest,
          definition: definition,
          verbalizer: verbalizer,
          language: detectedLang,
          userMessage: request.userMessage,
        );
        if (preflight != null) {
          logger.logFinalResponse(preflight);
          return AgentRuntimeResponse(
            finalMessage: preflight,
            success: true,
            state: AgentRuntimeState.askingUser,
            events: logger.events,
          );
        }

        // Check confirmation requirement.
        final crossWs = await _toolRouter.requiresCrossWorkspaceConfirmation(
          toolRequest,
        );
        final mustConfirm =
            (definition.requiresConfirmation || crossWs) &&
            !autoApproveSensitive;
        if (mustConfirm) {
          if (request.source == RequestSource.workflow) {
            logger.logStateChange(
              AgentRuntimeState.blockedSensitive,
              'Sensitive action blocked in workflow (allow-sensitive off): '
              '${toolRequest.name}',
            );
            emit(logger.events.last);
            await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
            return AgentRuntimeResponse(
              finalMessage: '',
              success: false,
              state: AgentRuntimeState.blockedSensitive,
              events: logger.events,
              pendingTool: toolRequest.name,
              pendingToolArgs: toolRequest.args,
            );
          }
          state = AgentRuntimeState.waitingConfirmation;
          logger.logStateChange(
            state,
            'Tool requires confirmation: ${toolRequest.name}',
          );
          emit(logger.events.last);

          final summary = await verbalizer.confirm(
            tool: toolRequest,
            definition: definition,
            language: detectedLang,
          );
          final preview = await verbalizer.preview(
            tool: toolRequest,
            language: detectedLang,
          );

          Map<String, dynamic>? resumeContext;
          String? ledgerIdForPending;
          if (goalTree.isNotEmpty && !goalTree.isComplete) {
            final active = goalTree.nextActionable;
            if (active != null) {
              active.status = SubgoalStatus.inProgress;
            }
            if (goalTree.subgoals.length > 1) {
              final ledger = await _taskScope.persistLedgerAtGate(
                request: request,
                plan: plan,
                goalTree: goalTree,
                previousResults: previousResults,
                currentStep: currentStep,
                availableTools: availableTools,
                memorySnapshot: memorySnapshot,
                detectedLangCode: detectedLang.code,
                autoApproveSensitive: autoApproveSensitive,
                isWorkflowAutoExecute: isWorkflowAutoExecute,
                pendingTool: toolRequest,
              );
              ledgerIdForPending = ledger.id;
            }
            resumeContext = {
              'ledger_id': ledgerIdForPending,
              'plan': plan,
              'goal_tree': goalTree.toJson(),
              'previous_results': previousResults,
              'current_step': currentStep,
              'available_tools': availableTools,
              'memory_snapshot': memorySnapshot,
              'auto_approve_sensitive': autoApproveSensitive,
              'is_workflow_auto_execute': isWorkflowAutoExecute,
              'language_code': detectedLang.code,
              'language_label': detectedLang.label,
              'language_script': detectedLang.script,
              'language_confidence': detectedLang.confidence,
              'user_message': request.userMessage,
            };
          }

          // Store as pending action — accessed via ConfirmationManager through
          // the engine's _pendingActions getter. The runner does not own the
          // pending-actions map; callers must provide it or we delegate via a
          // callback. We use a direct write via TaskScopeManager's confirmation
          // reference. But since we don't have direct access, we store on the
          // engine's getter via a callback set by the engine.

          // pendingActions is accessed at 2 sites in the loop. Engine sets a
          // callback on the runner after construction.
          final pending = PendingAction(
            toolName: toolRequest.name,
            toolArgs: toolRequest.args,
            userFacingSummary: summary,
            userFacingPreview: preview,
            languageCode: detectedLang.code,
            resumeContext: resumeContext,
          );
          _pendingActionsCallback?.call(request.agentId, pending);

          await _workspaceLoader.updateHeartbeat(
            request.agentName.isNotEmpty ? request.agentName : request.agentId,
            state: state.name,
            task: request.userMessage,
            lastTool: toolRequest.name,
          );

          return AgentRuntimeResponse(
            finalMessage: summary,
            success: true,
            state: AgentRuntimeState.waitingConfirmation,
            events: logger.events,
            pendingTool: toolRequest.name,
            pendingToolArgs: toolRequest.args,
          );
        }

        // Duplicate-delivery guard.
        final deliveryKey = deliveryDestinationKey(toolRequest);
        if (deliveryKey != null && deliveredKeys.contains(deliveryKey)) {
          logger.logStateChange(
            state,
            'Duplicate delivery suppressed: ${toolRequest.name} to an '
            'already-delivered destination ($deliveryKey).',
          );
          emit(logger.events.last);
          if (goalTree.isNotEmpty) {
            final active = goalTree.nextActionable;
            if (active != null) active.status = SubgoalStatus.done;
          }
          if (goalTree.isEmpty || goalTree.isComplete) {
            final priorTool = lastDeliveryTool ?? toolRequest;
            final priorResult =
                lastDeliveryResult ??
                ToolExecutionResult(success: true, toolName: toolRequest.name);
            final finalMsg = await verbalizer.success(
              tool: priorTool,
              result: priorResult,
              language: detectedLang,
            );
            logger.logFinalResponse(finalMsg);
            await _workspaceLoader.updateHeartbeat(
              request.agentName.isNotEmpty
                  ? request.agentName
                  : request.agentId,
              state: 'done',
              task: request.userMessage,
              lastTool: priorTool.name,
              lastResult: 'success',
            );
            await _taskScope.archiveLedgerForRequest(request, LedgerStatus.completed);
            return AgentRuntimeResponse(
              finalMessage: finalMsg,
              success: true,
              state: AgentRuntimeState.done,
              events: logger.events,
              actions: priorResult.actions,
            );
          }
          previousResults.add({
            'step': currentStep,
            'tool': toolRequest.name,
            'note': 'Duplicate delivery to $deliveryKey suppressed.',
          });
          currentStep++;
          retryCount = 0;
          continue;
        }

        // Execute tool.
        state = AgentRuntimeState.executingTool;
        logger.logStateChange(state, 'Executing ${toolRequest.name}');
        emit(logger.events.last);
        logger.logToolCall(toolRequest);

        final result = autoApproveSensitive
            ? await _toolRouter.forceExecute(toolRequest)
            : await _toolRouter.execute(toolRequest);
        logger.logToolResult(result);
        emit(logger.events.last);

        _memory.record(
          agentId: request.agentId,
          toolName: toolRequest.name,
          args: toolRequest.args,
          data: result.data,
          success: result.success,
          error: result.error,
        );

        if (deliveryKey != null && result.success) {
          deliveredKeys.add(deliveryKey);
          lastDeliveryTool = toolRequest;
          lastDeliveryResult = result;
        }

        final permissionFinal = permissionDeniedResponseFor(result);
        if (permissionFinal != null) {
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          logger.logFinalResponse(permissionFinal);
          await _workspaceLoader.updateHeartbeat(
            request.agentName.isNotEmpty ? request.agentName : request.agentId,
            state: 'failed',
            task: request.userMessage,
            lastTool: toolRequest.name,
            lastResult: 'permission_denied',
            lastError: result.error,
          );
          return AgentRuntimeResponse(
            finalMessage: permissionFinal,
            success: false,
            state: AgentRuntimeState.failed,
            events: logger.events,
          );
        }

        // Post-execute verification.
        if (postExecuteValidator != null && result.success) {
          final toolDef = _toolRouter.getDefinition(toolRequest.name);
          if (toolDef != null) {
            final verification = await postExecuteValidator.verify(
              tool: toolRequest,
              definition: toolDef,
              result: result,
            );
            if (verification.isUnverified) {
              logger.logError(
                'Post-execute verification failed: ${verification.reason} '
                '(entity=${verification.expectedEntity}, type=${verification.entityType})',
              );
              final recoveryDecision = await _maybeRecover(
                recovery: recovery,
                rethink: rethink,
                failedTool: toolRequest,
                reason: 'verification_unverified',
                logger: logger,
                unverifiedEntity: verification.expectedEntity,
                unverifiedEntityType: verification.entityType,
              );
              if (recoveryDecision != null) {
                return run(
                  request: request,
                  plan: recoveryDecision.plan,
                  goalTree: recoveryDecision.goalTree,
                  executor: executor,
                  verbalizer: verbalizer,
                  detectedLang: detectedLang,
                  availableTools: availableTools,
                  logger: logger,
                  emit: emit,
                  memorySnapshot: memorySnapshot,
                  recovery: recovery,
                  postExecuteValidator: postExecuteValidator,
                  rethink: rethink,
                  autoApproveSensitive: autoApproveSensitive,
                  isWorkflowAutoExecute: isWorkflowAutoExecute,
                );
              }
              await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
              final unverifiedMessage = verification.userFacingMessage(
                detectedLang,
              );
              logger.logFinalResponse(unverifiedMessage);
              return AgentRuntimeResponse(
                finalMessage: unverifiedMessage,
                success: false,
                state: AgentRuntimeState.failed,
                events: logger.events,
              );
            }
          }
        }

        // Short-circuit for last step + retrieval.
        final shortCircuitActive = goalTree.nextActionable;
        final retrievalCompletesTree =
            result.success &&
            shortCircuitActive != null &&
            _isRetrievalTool(toolRequest.name) &&
            !goalTree.subgoals.any(
              (s) => !s.isTerminal && s.id != shortCircuitActive.id,
            );
        final wouldCompleteTree =
            goalTree.isEmpty || goalTree.isComplete || retrievalCompletesTree;
        if (result.success &&
            _isLastPlannedStep(plan, currentStep) &&
            wouldCompleteTree) {
          if (retrievalCompletesTree) {
            shortCircuitActive.status = SubgoalStatus.done;
          }
          final verificationBlocker = await _completionVerifier.blockIfUnverified(
            request: request,
            plan: plan,
            goalTree: goalTree,
            previousResults: previousResults,
            currentStep: currentStep,
            availableTools: availableTools,
            memorySnapshot: memorySnapshot,
            detectedLang: detectedLang,
            autoApproveSensitive: autoApproveSensitive,
            isWorkflowAutoExecute: isWorkflowAutoExecute,
            logger: logger,
            parkTask: (questions) => _taskScope.parkForUserInput(
              request: request,
              plan: plan,
              goalTree: goalTree,
              previousResults: previousResults,
              currentStep: currentStep,
              availableTools: availableTools,
              memorySnapshot: memorySnapshot,
              detectedLangCode: detectedLang.code,
              autoApproveSensitive: autoApproveSensitive,
              isWorkflowAutoExecute: isWorkflowAutoExecute,
              questions: questions,
            ),
            lastToolName: toolRequest.name,
          );
          if (verificationBlocker != null) return verificationBlocker;
          final localFinal =
              shouldAnswerFromToolResult(
                toolName: toolRequest.name,
                userMessage: request.userMessage,
                result: result,
              )
              ? await verbalizer.answerFromToolResult(
                  userMessage: request.userMessage,
                  tool: toolRequest,
                  result: result,
                  language: detectedLang,
                )
              : await finalForCompletedTree(
                  goalTree: goalTree,
                  fallbackTool: toolRequest,
                  fallbackResult: result,
                  verbalizer: verbalizer,
                  language: detectedLang,
                  targetGraph: (plan['runtime_target_graph'] as Map?)
                      ?.cast<String, dynamic>(),
                );
          logger.logFinalResponse(localFinal);
          await _workspaceLoader.updateHeartbeat(
            request.agentName.isNotEmpty ? request.agentName : request.agentId,
            state: 'done',
            task: request.userMessage,
            lastTool: toolRequest.name,
            lastResult: 'success',
          );
          await _taskScope.archiveLedgerForRequest(request, LedgerStatus.completed);
          return AgentRuntimeResponse(
            finalMessage: localFinal,
            success: true,
            state: AgentRuntimeState.done,
            events: logger.events,
            actions: result.actions,
          );
        }

        await _workspaceLoader.updateHeartbeat(
          request.agentName.isNotEmpty ? request.agentName : request.agentId,
          state: state.name,
          task: request.userMessage,
          lastTool: toolRequest.name,
          lastResult: result.success ? 'success' : 'failed',
          lastError: result.error,
        );

        // Review result.
        state = AgentRuntimeState.reviewing;
        logger.logStateChange(state, 'Reviewing tool result');
        emit(logger.events.last);

        final review = await executor.review(
          result: result,
          plan: plan,
          currentStep: currentStep,
          userMessage: request.userMessage,
          logger: logger,
          language: detectedLang.label,
          goalTree: goalTree,
          recentMessages: loopRecentMsgs,
        );
        emit(logger.events.last);

        var reviewStatus = review?['status'] as String? ?? '';
        if (!result.success &&
            (reviewStatus == 'done' || reviewStatus == 'continue')) {
          reviewStatus = 'ask_user';
        }

        // Empty-result loop guard.
        if (result.success &&
            isEffectivelyEmpty(result.data) &&
            (reviewStatus == 'continue' || reviewStatus == 'retry')) {
          final priorEmpties = previousResults.where((p) {
            final tool = p['tool'] as String?;
            final data = p['result'];
            return tool == toolRequest.name &&
                data is Map<String, dynamic> &&
                isEffectivelyEmpty(data);
          }).length;
          if (priorEmpties >= 1 || isReadOnlyLookup(toolRequest.name)) {
            logger.logStateChange(
              state,
              'Empty-result loop guard: forcing done (tool=${toolRequest.name})',
            );
            reviewStatus = 'done';
            review?['status'] = 'done';
            review?['final_response'] ??= _emptyResultMessage(
              detectedLang.code,
              toolRequest.name,
            );
          }
        }

        if (review != null) {
          final reviewNarrative = (review['narrative'] ?? '').toString();
          if (reviewNarrative.isNotEmpty) {
            logger.logNarrative('review', reviewNarrative);
            emit(logger.events.last);
          }
        }

        if (review != null) {
          final update = review['subgoal_update'] as Map<String, dynamic>?;
          if (update != null) {
            var status = SubgoalStatusX.fromLabel(update['status'] as String?);
            if (!result.success && status == SubgoalStatus.done) {
              status = reviewStatus == 'failed'
                  ? SubgoalStatus.failed
                  : SubgoalStatus.inProgress;
            }
            final ok = goalTree.applyStatusUpdate(
              subgoalId: (update['id'] ?? '').toString(),
              status: status,
              resultRef: update['result_ref'] as String?,
              notes: update['notes'] as String?,
            );
            if (!ok) {
              final active = goalTree.nextActionable;
              if (active != null && result.success) {
                active.status = SubgoalStatus.done;
              }
            }
          } else if (result.success) {
            final active = goalTree.nextActionable;
            if (active != null) active.status = SubgoalStatus.done;
          } else {
            final active = goalTree.nextActionable;
            if (active != null) active.status = SubgoalStatus.inProgress;
          }
        }

        if (review == null) {
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          return fail('Review phase failed.', logger);
        }

        if (reviewStatus == 'done') {
          if (goalTree.isNotEmpty && !goalTree.isComplete) {
            logger.logError(
              'Reviewer tried to finish early. Goal tree still has '
              '${goalTree.subgoals.where((s) => !s.isTerminal).length} subgoal(s) outstanding. Continuing.',
            );
            previousResults.add({
              'step': currentStep,
              'tool': toolRequest.name,
              'result': result.data,
              'note':
                  'Reviewer status=done overridden because subgoals remain.',
            });
            currentStep++;
            retryCount = 0;
            continue;
          }

          final finalResponse =
              shouldAnswerFromToolResult(
                toolName: toolRequest.name,
                userMessage: request.userMessage,
                result: result,
              )
              ? await verbalizer.answerFromToolResult(
                  userMessage: request.userMessage,
                  tool: toolRequest,
                  result: result,
                  language: detectedLang,
                )
              : review['final_response'] as String? ?? 'Task completed.';
          final verificationBlocker = await _completionVerifier.blockIfUnverified(
            request: request,
            plan: plan,
            goalTree: goalTree,
            previousResults: previousResults,
            currentStep: currentStep,
            availableTools: availableTools,
            memorySnapshot: memorySnapshot,
            detectedLang: detectedLang,
            autoApproveSensitive: autoApproveSensitive,
            isWorkflowAutoExecute: isWorkflowAutoExecute,
            logger: logger,
            parkTask: (questions) => _taskScope.parkForUserInput(
              request: request,
              plan: plan,
              goalTree: goalTree,
              previousResults: previousResults,
              currentStep: currentStep,
              availableTools: availableTools,
              memorySnapshot: memorySnapshot,
              detectedLangCode: detectedLang.code,
              autoApproveSensitive: autoApproveSensitive,
              isWorkflowAutoExecute: isWorkflowAutoExecute,
              questions: questions,
            ),
            lastToolName: toolRequest.name,
          );
          if (verificationBlocker != null) return verificationBlocker;
          final completedFinal =
              goalTree.isNotEmpty &&
                  goalTree.subgoals
                          .where(
                            (s) =>
                                s.status == SubgoalStatus.done ||
                                s.status == SubgoalStatus.failed ||
                                s.status == SubgoalStatus.skipped,
                          )
                          .length >
                      1
              ? await finalForCompletedTree(
                  goalTree: goalTree,
                  fallbackTool: toolRequest,
                  fallbackResult: result,
                  verbalizer: verbalizer,
                  language: detectedLang,
                  targetGraph: (plan['runtime_target_graph'] as Map?)
                      ?.cast<String, dynamic>(),
                )
              : finalResponse;
          logger.logFinalResponse(completedFinal);
          await _workspaceLoader.updateHeartbeat(
            request.agentName.isNotEmpty ? request.agentName : request.agentId,
            state: 'done',
            task: request.userMessage,
            lastTool: toolRequest.name,
            lastResult: 'success',
          );
          await _taskScope.archiveLedgerForRequest(request, LedgerStatus.completed);
          return AgentRuntimeResponse(
            finalMessage: completedFinal,
            success: true,
            state: AgentRuntimeState.done,
            events: logger.events,
            actions: result.success ? result.actions : const [],
          );
        }

        if (reviewStatus == 'ask_user') {
          if (!result.success && !_failedToolCanAskUser(result)) {
            if (_isCapabilityBoundaryFailure(result)) {
              await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
              return fail(_capabilityNotFoundMessage(detectedLang), logger);
            }
            reviewStatus = 'failed';
          } else {
            final question =
                review['question'] as String? ??
                await fallbackQuestionForToolFailure(
                  result,
                  detectedLang,
                  verbalizer,
                );
            await _taskScope.parkForUserInput(
              request: request,
              plan: plan,
              goalTree: goalTree,
              previousResults: previousResults,
              currentStep: currentStep,
              availableTools: availableTools,
              memorySnapshot: memorySnapshot,
              detectedLangCode: detectedLang.code,
              autoApproveSensitive: autoApproveSensitive,
              isWorkflowAutoExecute: isWorkflowAutoExecute,
              questions: [question],
            );
            return AgentRuntimeResponse(
              finalMessage: question,
              success: true,
              state: AgentRuntimeState.askingUser,
              events: logger.events,
            );
          }
        }

        if (reviewStatus == 'failed') {
          final recoveryDecision = await _maybeRecover(
            recovery: recovery,
            rethink: rethink,
            failedTool: toolRequest,
            reason: 'tool_failed',
            errorSummary: review['error']?.toString() ?? '',
            logger: logger,
          );
          if (recoveryDecision != null) {
            return run(
              request: request,
              plan: recoveryDecision.plan,
              goalTree: recoveryDecision.goalTree,
              executor: executor,
              verbalizer: verbalizer,
              detectedLang: detectedLang,
              availableTools: availableTools,
              logger: logger,
              emit: emit,
              memorySnapshot: memorySnapshot,
              recovery: recovery,
              postExecuteValidator: postExecuteValidator,
              rethink: rethink,
              autoApproveSensitive: autoApproveSensitive,
              isWorkflowAutoExecute: isWorkflowAutoExecute,
            );
          }
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          final giveUp =
              recovery?.giveUpMessage(detectedLang) ??
              (review['error'] as String? ?? 'Unrecoverable error.');
          return fail(giveUp, logger);
        }

        if (reviewStatus == 'retry' && retryCount < 1) {
          retryCount++;
          previousResults.add({
            'step': currentStep,
            'tool': toolRequest.name,
            'result': result.data,
            'retried': true,
          });
          continue;
        }

        previousResults.add({
          'step': currentStep,
          'tool': toolRequest.name,
          'result': result.data,
        });
        currentStep++;
        retryCount = 0;
      }
    }

    await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
    return fail(
      'Maximum runtime steps ($adaptiveLimit) reached without completion.',
      logger,
    );
  }

  // ---------------------------------------------------------------------------
  // Recovery
  // ---------------------------------------------------------------------------

  Future<({Map<String, dynamic> plan, GoalTree goalTree})?> _maybeRecover({
    required RecoveryCoordinator? recovery,
    required Future<({Map<String, dynamic> plan, GoalTree goalTree})?>
    Function()?
    rethink,
    required String reason,
    required RuntimeLogger logger,
    ToolCallRequest? failedTool,
    String stageHint = '',
    String errorSummary = '',
    String unverifiedEntity = '',
    String unverifiedEntityType = '',
  }) async {
    if (recovery == null || rethink == null) return null;

    final toolMarker = failedTool?.name ?? stageHint;
    final argsSummary = failedTool == null
        ? errorSummary
        : _summarizeArgs(failedTool.args);

    recovery.recordAttemptFailure(
      RecoveryAttempt(
        reason: reason,
        failedToolName: toolMarker,
        failedArgsSummary: argsSummary,
        unverifiedEntity: unverifiedEntity,
        unverifiedEntityType: unverifiedEntityType,
      ),
    );

    final decision = recovery.evaluate(
      snapshotMaybeStale: reason == 'verification_unverified',
    );
    if (decision != RecoveryDecision.rethinkAndReplan) {
      logger.logError(
        'Recovery decision=${decision.name} after $reason '
        '(attempts=${recovery.attemptCount}/${recovery.maxAttempts})',
      );
      return null;
    }

    logger.logStateChange(
      AgentRuntimeState.analyzing,
      'Recovery: re-reflecting with prior failure context '
      '(attempt ${recovery.attemptCount}/${recovery.maxAttempts}, reason=$reason)',
    );

    final replan = await rethink();
    if (replan == null) {
      logger.logError('Recovery: rethink returned no new plan; giving up.');
      return null;
    }
    logger.logLlmDecision('recovery.replan', {
      'attempt': recovery.attemptCount,
      'reason': reason,
      'subgoals': replan.goalTree.subgoals.length,
    });
    return replan;
  }

  String _summarizeArgs(Map<String, dynamic> args) {
    if (args.isEmpty) return '';
    final parts = <String>[];
    args.forEach((key, value) {
      final v = value?.toString() ?? '';
      final truncated = v.length > 24 ? '${v.substring(0, 24)}…' : v;
      parts.add('$key=$truncated');
    });
    return parts.take(4).join(', ');
  }

  // ---------------------------------------------------------------------------
  // Public helpers — shared with engine's _executePendingTool
  // ---------------------------------------------------------------------------

  /// Build a failure response.
  AgentRuntimeResponse fail(String message, RuntimeLogger logger) {
    logger.logError(message);
    return AgentRuntimeResponse(
      finalMessage: message,
      success: false,
      state: AgentRuntimeState.failed,
      events: logger.events,
    );
  }

  /// Check if the tool result warrants answering directly vs. going through the
  /// full review pipeline.
  bool shouldAnswerFromToolResult({
    required String toolName,
    required String userMessage,
    required ToolExecutionResult result,
  }) {
    if (!result.success || result.data == null || result.data!.isEmpty) {
      return false;
    }
    if (userMessage.trim().isEmpty) return false;
    return _isRetrievalTool(toolName);
  }

  /// Build a localized permission-denied response when the tool result carries
  /// the permission-denied error code.
  String? permissionDeniedResponseFor(ToolExecutionResult result) {
    final data = result.data;
    if (data == null ||
        data['errorCode'] != ToolPermissionPolicy.permissionDeniedCode) {
      return null;
    }

    final code = _languageCode;
    final reason = data['reason'] as String? ?? '';
    final moduleName = (data['moduleName'] as String? ?? '').trim();
    final module = moduleName.isEmpty
        ? LanguageRegistry.phrase('permission_module_default', code)
        : moduleName;

    final action = (data['actionLabel'] as String? ?? '').trim();
    final actionLabel = action.isEmpty
        ? LanguageRegistry.phrase('permission_action_default', code)
        : action;

    final setting = (data['settingLabel'] as String? ?? '').trim();
    if (setting.isNotEmpty) {
      return LanguageRegistry.phrase(
        'permission_setting_disabled',
        code,
        {'module': module, 'setting': setting, 'action': actionLabel},
      );
    }

    return LanguageRegistry.phrase(
      'permission_denied',
      code,
      {'module': module, 'action': actionLabel, 'reason': reason},
    );
  }

  /// Build the final user-facing message when the goal tree completes.
  Future<String> finalForCompletedTree({
    required GoalTree goalTree,
    required ToolCallRequest fallbackTool,
    required ToolExecutionResult fallbackResult,
    required ToolVerbalizer verbalizer,
    required DetectedLanguage language,
    Map<String, dynamic>? targetGraph,
  }) async {
    if (goalTree.isNotEmpty &&
        goalTree.subgoals
                .where(
                  (s) =>
                      s.status == SubgoalStatus.done ||
                      s.status == SubgoalStatus.failed ||
                      s.status == SubgoalStatus.skipped,
                )
                .length >
            1) {
      final summaries = goalTree.subgoals
          .where(
            (s) =>
                s.status == SubgoalStatus.done ||
                s.status == SubgoalStatus.failed ||
                s.status == SubgoalStatus.skipped,
          )
          .map((s) => _subgoalToSummary(s))
          .toList(growable: false);
      return await verbalizer.taskSummary(
        mainGoal: goalTree.mainGoal,
        completedSubgoals: summaries,
        language: language,
      );
    }

    // Single subgoal or empty tree: use the standard per-tool success path.
    return await verbalizer.success(
      tool: fallbackTool,
      result: fallbackResult,
      language: language,
    );
  }

  Map<String, String> _subgoalToSummary(Subgoal s) {
    return {
      'label': s.label,
      'status': s.status.name,
      'result': (s.notes ?? '').trim(),
    };
  }

  /// Build a natural-language fallback question when a tool fails and the
  /// reviewer did not produce one.
  Future<String> fallbackQuestionForToolFailure(
    ToolExecutionResult result,
    DetectedLanguage language,
    ToolVerbalizer verbalizer,
  ) async {
    final providers = result.data?['providers'] as List?;
    if (providers != null && providers.isNotEmpty) {
      final names = providers
          .whereType<Map>()
          .map(
            (p) => (p['nickname'] ?? p['name'] ?? p['model'] ?? '').toString(),
          )
          .where((p) => p.trim().isNotEmpty)
          .join(', ');
      return await verbalizer.providerDisambiguation(
        availableProviders: names,
        language: language,
      );
    }

    final data = result.data;
    final error = (result.error ?? '').trim();
    String? availableNames;
    String? triedName;

    if (data != null &&
        data['available'] is List &&
        (data['available'] as List).isNotEmpty) {
      final available = data['available'] as List;
      availableNames = available
          .whereType<Map>()
          .map((m) => (m['name'] ?? '').toString())
          .where((n) => n.trim().isNotEmpty)
          .join(', ');
      final tried = data['tried'];
      triedName = tried is Map
          ? (tried['name'] ?? tried['id'] ?? '')?.toString()
          : null;
    }

    return await verbalizer.fallbackQuestion(
      error: error,
      availableNames: availableNames,
      triedName: triedName,
      language: language,
    );
  }

  // ---------------------------------------------------------------------------
  // Static helpers — pure functions with no service dependencies
  // ---------------------------------------------------------------------------

  /// True when a tool's data payload represents an empty / zero-match outcome.
  static bool isEffectivelyEmpty(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return true;
    final count = data['count'];
    if (count is num && count == 0) return true;
    const listKeys = [
      'results', 'items', 'events', 'notes', 'files', 'matches',
      'apps', 'recent', 'list', 'data', 'slots', 'conflicts', 'tree',
    ];
    var sawList = false;
    for (final k in listKeys) {
      final v = data[k];
      if (v is List) {
        sawList = true;
        if (v.isNotEmpty) return false;
      } else if (v is Map) {
        sawList = true;
        if (v.isNotEmpty) return false;
      }
    }
    return sawList;
  }

  /// True when the tool is a read-only lookup.
  static bool isReadOnlyLookup(String toolName) {
    return toolName.endsWith('.search') ||
        toolName.endsWith('.list') ||
        toolName.endsWith('.list_recent') ||
        toolName.endsWith('.read') ||
        toolName.endsWith('.read_recent') ||
        toolName.endsWith('.tree') ||
        toolName.endsWith('.metadata') ||
        toolName.endsWith('.upcoming') ||
        toolName.endsWith('.today') ||
        toolName.endsWith('.conflicts') ||
        toolName.endsWith('.free_slot') ||
        toolName.endsWith('.status') ||
        toolName.endsWith('.summary') ||
        toolName.endsWith('.classify') ||
        toolName.endsWith('.summarize');
  }

  /// Returns a stable destination key for duplicate-delivery suppression.
  static String? deliveryDestinationKey(ToolCallRequest tool) {
    switch (tool.name) {
      case 'chat.send':
        final agentId = (tool.args['agentId'] ?? '').toString().trim();
        return 'chat.send|${agentId.isEmpty ? 'self' : agentId}';
      case 'notification.create_local':
        return 'notification.create_local';
      default:
        return null;
    }
  }

  /// User-facing message when no tool exists for the requested action.
  String _capabilityNotFoundMessage(DetectedLanguage lang) {
    final code = lang.code.toLowerCase();
    if (code == 'id' || code.startsWith('id_')) {
      return 'Maaf, aku belum punya kemampuan untuk melakukan itu. '
          'Tidak ada tool yang sesuai untuk permintaan tersebut.';
    }
    return 'Sorry, I don\'t have the capability to do that. '
        'No tool is available for this request.';
  }

  /// Localized "no results" reply when the empty-result loop guard fires.
  static String emptyResultMessage(String langCode, String toolName) {
    final code = langCode.toLowerCase();
    final isFiles = toolName.startsWith('files.');
    final isNotes = toolName.startsWith('notes.');
    final isCal = toolName.startsWith('calendar.');
    if (code == 'id' || code.startsWith('id_')) {
      if (isFiles) return 'Tidak ada file yang cocok dengan kriteria itu.';
      if (isNotes) return 'Tidak ada catatan yang cocok dengan kriteria itu.';
      if (isCal) return 'Tidak ada acara yang cocok dengan kriteria itu.';
      return 'Tidak ada hasil yang cocok.';
    }
    if (isFiles) return 'No files match that criteria.';
    if (isNotes) return 'No notes match that criteria.';
    if (isCal) return 'No events match that criteria.';
    return 'No results match.';
  }

  // ---------------------------------------------------------------------------
  // Private helpers — loop-internal only
  // ---------------------------------------------------------------------------

  bool _isLastPlannedStep(Map<String, dynamic> plan, int currentStep) {
    final steps = plan['steps'];
    if (steps is List && steps.isNotEmpty) {
      return currentStep >= steps.length;
    }
    final subgoals = plan['subgoals'];
    if (subgoals is List && subgoals.isNotEmpty) {
      return currentStep >= subgoals.length;
    }
    return true;
  }

  bool _isRetrievalTool(String toolName) {
    final def = _toolRouter.getDefinition(toolName);
    if (def != null && def.isRetrieval) return true;
    final name = toolName.toLowerCase();
    if (name.endsWith('.read') ||
        name.endsWith('.list') ||
        name.endsWith('.search') ||
        name.endsWith('.summarize') ||
        name.endsWith('.classify') ||
        name.endsWith('.status') ||
        name.endsWith('.today') ||
        name.endsWith('.self')) {
      return true;
    }
    if (name == 'system.self' ||
        name == 'app.list_installed' ||
        name == 'notification.read_recent' ||
        name == 'system.agents.list' ||
        name == 'system.providers.list' ||
        name == 'system.modules.list' ||
        name == 'system.tools.list') {
      return true;
    }
    if (name.startsWith('device.') &&
        !name.endsWith('.set') &&
        !name.contains('reconnect')) {
      return true;
    }
    return false;
  }

  bool _isAnswerOnlySubgoal(Subgoal subgoal) {
    final op = _subgoalSlot(subgoal, const [
      '_operation',
      'operation',
      'action',
      'kind',
    ]).toLowerCase();
    if (const {
      'respond',
      'answer',
      'final_response',
      'synthesize',
      'summarize_for_user',
    }.contains(op)) {
      return true;
    }

    final tool = _subgoalSlot(subgoal, const ['tool', 'tool_name']);
    return tool.toLowerCase() == 'none';
  }

  String _subgoalSlot(Subgoal subgoal, List<String> keys) {
    for (final key in keys) {
      final value = subgoal.requiredSlots[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String _emptyResultMessage(String langCode, String toolName) {
    final code = langCode.toLowerCase();
    final isFiles = toolName.startsWith('files.');
    final isNotes = toolName.startsWith('notes.');
    final isCal = toolName.startsWith('calendar.');
    if (code == 'id' || code.startsWith('id_')) {
      if (isFiles) return 'Tidak ada file yang cocok dengan kriteria itu.';
      if (isNotes) return 'Tidak ada catatan yang cocok dengan kriteria itu.';
      if (isCal) return 'Tidak ada acara yang cocok dengan kriteria itu.';
      return 'Tidak ada hasil yang cocok.';
    }
    if (isFiles) return 'No files match that criteria.';
    if (isNotes) return 'No notes match that criteria.';
    if (isCal) return 'No events match that criteria.';
    return 'No results match.';
  }

  bool _failedToolCanAskUser(ToolExecutionResult result) {
    final data = result.data;
    if (data != null) {
      final available = data['available'];
      if (available is List && available.isNotEmpty) return true;
      final providers = data['providers'];
      if (providers is List && providers.isNotEmpty) return true;
    }
    final error = (result.error ?? '').toLowerCase();
    return error.contains('required') || error.contains('missing');
  }

  bool _isCapabilityBoundaryFailure(ToolExecutionResult result) {
    final text = '${result.error ?? ''} ${result.toolName}'.toLowerCase();
    return text.contains('tool not found') ||
        text.contains('unknown tool') ||
        text.contains('not registered') ||
        text.contains('no implementation') ||
        text.contains('no tool') ||
        text.contains('capability') ||
        text.contains('unavailable') ||
        text.contains('unsupported');
  }

  // ---------------------------------------------------------------------------
  // Callback for pending-actions write (engine owns the map)
  // ---------------------------------------------------------------------------

  /// Set by the engine after construction. The runner writes to the engine's
  /// `_pendingActions` map via this callback when a confirmation gate fires.
  void Function(String agentId, PendingAction pending)? _pendingActionsCallback;

  /// Attach the pending-actions write callback. Called by the engine.
  void attachPendingActionsCallback(
    void Function(String agentId, PendingAction pending) callback,
  ) {
    _pendingActionsCallback = callback;
  }
}
