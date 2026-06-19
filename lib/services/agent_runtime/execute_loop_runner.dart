import '../llm/llm_error_mapper.dart';
import 'action_map.dart';
import 'completion_verifier.dart';
import 'executor.dart';
import 'goal_tree.dart';
import 'language_detector.dart';
import 'language_registry.dart';
import 'narrative_narrator.dart';
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

/// Runs the main tool-execution loop for the agentic runtime.
///
/// Extracted from [AgentRuntimeEngine] as Phase 5 of the runtime decomposition.
/// Owns the 1,133-line `_executeLoop`, `_maybeRecover`, `_summarizeArgs`, and
/// ~12 helper methods. Depends on six injected services; all per-call data is
/// threaded through `run()` parameters.
class ExecuteLoopRunner {
  ExecuteLoopRunner({
    required ToolRouter toolRouter,
    required TaskScopeManager taskScope,
    required PreflightChecker preflight,
    required CompletionVerifier completionVerifier,
    required RuntimeMemory memory,
    required String languageCode,
  }) : _toolRouter = toolRouter,
       _taskScope = taskScope,
       _preflight = preflight,
       _completionVerifier = completionVerifier,
       _memory = memory,
       _languageCode = languageCode;

  final ToolRouter _toolRouter;
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
    bool fastPath = false,
  }) async {
    final previousResults = <Map<String, dynamic>>[...?initialPreviousResults];
    var currentStep = initialStep;
    var retryCount = 0;
    var rePlanned = false;
    final stuck = StuckDetector();
    // Soft-guard: track tools we've already hinted about so a stubborn
    // selector that re-picks the same off-path tool falls through instead of
    // looping forever. After one hint, second pick is allowed (let stuck
    // detector handle it from there).
    final offPathHinted = <String>{};

    // Idempotency tracking for delivery/side-effect tools.
    final deliveredKeys = <String>{};
    ToolCallRequest? lastDeliveryTool;
    ToolExecutionResult? lastDeliveryResult;

    // Conversation history snapshot (latest 20, chronological).
    // Provider-error sentinel messages are stripped first — they describe a
    // past connection failure, not real conversational context, and must not
    // leak into the executor or reviewer prompts.
    final loopRecentMsgs = () {
      final src = request.recentMessages
          .where(
            (m) =>
                m.includeInRuntimeContext &&
                !LlmErrorMapper.isProviderErrorMessage(m.content),
          )
          .toList();
      final latest = src.length > 20 ? src.sublist(src.length - 20) : src;
      return latest.map((m) => {'role': m.role, 'content': m.content}).toList();
    }();

    // Adaptive budget: base + 2 steps per subgoal, hard-capped at maxSteps×3.
    // Fast-path tasks get a hard cap of 2 iterations — if exhausted, the caller
    // retries in normal mode.
    final adaptiveLimit = fastPath
        ? 2
        : goalTree.isEmpty
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
      if (logger.logPreActionNarrative(
        'choosing',
        NarrativeNarrator.narrateNext('choosing', detectedLang.code),
      )) {
        emit(logger.events.last);
      }

      // Fast-path: try native function calling before JSON selector.
      // If successful, synthesize a selection map that the rest of the loop
      // can process identically. Falls back to JSON on null.
      Map<String, dynamic>? selection;
      if (fastPath && executor.config.supportsFunctionCalling) {
        final toolDefs = availableTools
            .map((desc) {
              final name = desc.split(':').first.replaceFirst('- ', '').trim();
              return _toolRouter.getDefinition(name);
            })
            .whereType<ToolDefinition>()
            .toList();
        final fcResult = await executor.selectToolViaFunctionCalling(
          tools: toolDefs,
          userGoal: request.userMessage,
          recentMessages: loopRecentMsgs,
          logger: logger,
        );
        if (fcResult != null) {
          // Synthesize a selection map compatible with the JSON selector shape.
          selection = {
            'status': 'tool_required',
            'tool': {
              'name': fcResult.name,
              'args': fcResult.args,
              'risk': fcResult.risk,
              'requires_confirmation': fcResult.requiresConfirmation,
            },
            'narrative': '',
          };
          logger.logLlmDecision('selectTool', selection);
          emit(logger.events.last);
        } else {
          logger.logDivergence('fc_fallback_to_json', {'step': currentStep});
        }
      }

      // JSON selector fallback (also the default for non-FC paths).
      selection ??= await executor.selectTool(
        plan: plan,
        currentStep: currentStep,
        previousResults: previousResults,
        availableTools: availableTools,
        logger: logger,
        userMessage: request.userMessage,
        recentToolMemory: memorySnapshot,
        isWorkflowAutoExecute: isWorkflowAutoExecute,
        goalTree: goalTree,
        recentMessages: loopRecentMsgs,
        agentName: request.agentName.isNotEmpty
            ? request.agentName
            : request.agentId,
        agentId: request.agentId,
      );
      emit(logger.events.last);

      if (selection == null) {
        if (nullSelectionRecoveryCount >= 1) {
          logger.logError(
            'Repeated null tool selection. Aborting to prevent infinite loop.',
          );
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          return fail(_capabilityNotFoundMessage(), logger);
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
            initialPreviousResults: previousResults,
            initialStep: currentStep,
            nullSelectionRecoveryCount: nullSelectionRecoveryCount + 1,
          );
        }
        await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
        return fail(
          recovery?.giveUpMessage(_settingsLanguage()) ??
              _capabilityNotFoundMessage(),
          logger,
        );
      }
      final selectionEvidenceRef = 'runtime_event:${logger.events.last.id}';

      // Extract status BEFORE emitting narrative so we can gate it against
      // the actual decision (kills "Got it, doing X" + status=ask_user desync).
      final status = selection['status'] as String? ?? '';
      final rawSelectNarrative = (selection['narrative'] ?? '').toString();
      final selectNarrative = NarrativeNarrator.gate(
        llmNarrative: rawSelectNarrative,
        decision: status,
        languageCode: detectedLang.code,
      );
      if (selectNarrative != rawSelectNarrative &&
          rawSelectNarrative.isNotEmpty) {
        logger.logDivergence('narrative_gate_override', {
          'phase': 'select_tool',
          'decision': status,
        });
      }
      // 'select_tool' is NOT a chat-bubble phase (per-step tool chatter caused
      // the stacked duplicate narratives).

      if (status == 'done') {
        final finalResponse =
            selection['final_response'] as String? ??
            _runtimePhrase('runtime_task_completed');
        if (goalTree.isNotEmpty && !goalTree.isComplete) {
          final active = goalTree.nextActionable;
          if (active != null && _isAnswerOnlySubgoal(active)) {
            active.status = SubgoalStatus.done;
            active.notes = 'answered_user';
          }
        }
        if (goalTree.isNotEmpty && !goalTree.isComplete) {
          // Count how many times LLM returned "done" without any tool executed.
          final toolsExecutedSoFar = previousResults
              .where((r) => r.containsKey('tool'))
              .length;
          final prematureDoneCount = previousResults
              .where(
                (r) =>
                    r['note']?.toString().contains(
                      'status=done but subgoals',
                    ) ==
                    true,
              )
              .length;

          // If LLM has said "done" 2+ times with zero tools executed, abort.
          if (prematureDoneCount >= 2 && toolsExecutedSoFar == 0) {
            logger.logError(
              'LLM returned status=done $prematureDoneCount times without '
              'executing any tool. Aborting to prevent infinite loop.',
            );
            await _taskScope.finishScopeForRequest(
              request,
              LedgerStatus.failed,
            );
            return fail(
              _runtimePhrase('runtime_tool_selection_missing'),
              logger,
            );
          }

          // Even AFTER a tool has run, a selector that keeps oscillating
          // done/tool re-narrates every pass and burns the budget. Bound it:
          // 3+ premature-done overrides means the selector cannot converge —
          // synthesize from what we have instead of looping to exhaustion.
          if (prematureDoneCount >= 3) {
            logger.logError(
              'Selector oscillated on status=done $prematureDoneCount times '
              'after executing $toolsExecutedSoFar tool(s). Stopping the loop '
              'and synthesizing from available results.',
            );
            return await _finishFromResults(
              request: request,
              previousResults: previousResults,
              goalTree: goalTree,
              verbalizer: verbalizer,
              detectedLang: detectedLang,
              logger: logger,
              emit: emit,
            );
          }

          logger.logDivergence('premature_done_overridden', {
            'source': 'selector',
            'remaining_subgoals': goalTree.subgoals
                .where((s) => !s.isTerminal)
                .length,
            'step': currentStep,
          });
          logger.logError(
            'Selector tried to finish early but goal tree is incomplete '
            '(${goalTree.subgoals.where((s) => !s.isTerminal).length} subgoals remaining). Continuing loop.',
          );
          previousResults.add({
            'step': currentStep,
            'note':
                'SYSTEM ERROR: You returned status=done but subgoals remain '
                'and NO tool was executed. You MUST select status=tool_required '
                'and call the appropriate tool. Do NOT return status=done until '
                'a tool has been executed for this task.',
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

        if (goalTree.isNotEmpty && goalTree.isComplete) {
          _emitTaskLedger(emit, request, goalTree);
        }
        logger.logFinalResponse(finalResponse);
        await _taskScope.archiveLedgerForRequest(
          request,
          LedgerStatus.completed,
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
              selection['question'] as String? ??
              _runtimePhrase('runtime_need_more_information'),
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
            initialPreviousResults: previousResults,
            initialStep: currentStep,
          );
        }
        await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
        return fail(
          recovery?.giveUpMessage(_settingsLanguage()) ??
              (selection['error'] as String? ??
                  _runtimePhrase('runtime_failed')),
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
              initialPreviousResults: previousResults,
              initialStep: currentStep,
            );
          }
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          return fail(
            recovery?.giveUpMessage(_settingsLanguage()) ??
                _runtimePhrase('runtime_tool_selection_missing'),
            logger,
          );
        }

        final toolRequest = ToolCallRequest.fromJson(toolJson);

        // ─── SOFT GUARD: canonical action map off-path detection ───────────
        // If the analyzer's intent maps to a canonical tool path and the
        // selector picked an off-path tool (e.g. files.mkdir to scaffold an
        // agent instead of system.config.patch), do NOT execute it. Inject a
        // structured hint and force one re-selection. This is a SOFT guard:
        // it only fires when the intent is in the map AND the chosen tool is
        // explicitly listed as off-path — unknown intents pass through.
        final guardIntent = (plan['intent'] ?? '').toString();
        if (guardIntent.isNotEmpty &&
            !offPathHinted.contains(toolRequest.name)) {
          final canonical = checkOffPath(guardIntent, toolRequest.name);
          if (canonical != null && canonical.isNotEmpty) {
            offPathHinted.add(toolRequest.name);
            logger.logError(
              'Soft guard: "${toolRequest.name}" is off-path for intent '
              '"$guardIntent". Canonical: ${canonical.join(", ")}. '
              'Injecting hint and re-selecting.',
            );
            previousResults.add({
              'step': currentStep,
              'note':
                  'OFF-PATH TOOL REJECTED: "${toolRequest.name}" is not the '
                  'canonical tool for this outcome. Use one of: '
                  '${canonical.join(", ")}. The runtime handles side effects '
                  '(workspace folders, template files) automatically — do not '
                  'assemble the result manually with file operations.',
            });
            currentStep++;
            continue;
          }
        }

        // Stuck detection (semantic — keys on tool + target entity so a
        // selector that loops on the same target while tweaking incidental
        // args still trips).
        if (stuck.observe(
          toolName: toolRequest.name,
          args: toolRequest.args,
          target: _targetFromArgs(toolRequest.args),
        )) {
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
              initialPreviousResults: previousResults,
              initialStep: currentStep,
            );
          }
          // Surface the most recent concrete failure if `previousResults` has
          // one — a real stderr/error line beats the canned "I hit a technical
          // issue" abort message. Falls through to the generic verbalizer when
          // there is nothing concrete to surface.
          final lastFailureCause = _lastFailureCauseFrom(previousResults);
          final abortMsg = lastFailureCause.isNotEmpty
              ? lastFailureCause
              : recovery?.giveUpMessage(_settingsLanguage()) ??
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
          return fail(_capabilityNotFoundMessage(), logger);
        }

        final definition = _toolRouter.getDefinition(toolRequest.name)!;

        final permissionDenied = await _toolRouter.permissionDeniedResult(
          toolRequest.name,
        );
        if (permissionDenied != null) {
          logger.logToolResult(permissionDenied);
          emit(logger.events.last);
          // Do NOT record permission/module denial in RuntimeMemory. These are
          // mutable environment conditions: the user may enable the module or
          // grant Android permission before the next turn. Persisting the denial
          // makes analyzer/selector prompts repeat stale "permission denied"
          // context even after the live permission state has changed.
          final finalResponse =
              permissionDeniedResponseFor(permissionDenied) ??
              (permissionDenied.error ??
                  _runtimePhrase('runtime_permission_denied'));
          final actions = permissionDeniedActionsFor(permissionDenied);

          // Park the task as a resumable pending action rather than discarding
          // it. The blocked tool is queued with the full goal-tree/plan state so
          // that once the user enables the module/permission and says "lanjut",
          // THIS (recent) task resumes — instead of a stale older ledger being
          // grabbed by the continuation path. Only park when there is real
          // progress to resume; trivial single-shot reads just fail.
          if (request.source == RequestSource.chat &&
              goalTree.isNotEmpty &&
              !goalTree.isComplete) {
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
            final pending = PendingAction(
              toolName: toolRequest.name,
              toolArgs: toolRequest.args,
              userFacingSummary: finalResponse,
              languageCode: detectedLang.code,
              resumeContext: {
                'ledger_id': ledger.id,
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
              },
            );
            _pendingActionsCallback?.call(request.agentId, pending);
          } else {
            await _taskScope.finishScopeForRequest(
              request,
              LedgerStatus.failed,
            );
          }
          logger.logFinalResponse(finalResponse);
          return AgentRuntimeResponse(
            finalMessage: finalResponse,
            success: false,
            state: AgentRuntimeState.failed,
            events: logger.events,
            actions: actions,
          );
        }

        // Pre-flight typo/existence check.
        final preflight = await _preflight.check(
          tool: toolRequest,
          definition: definition,
          verbalizer: verbalizer,
          language: detectedLang,
          userMessage: request.userMessage,
          currentAgentId: request.agentId,
          currentAgentName: request.agentName,
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
            await _taskScope.finishScopeForRequest(
              request,
              LedgerStatus.failed,
            );
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
              _emitTaskLedger(emit, request, goalTree);
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
            if (active != null) {
              active.status = SubgoalStatus.done;
              _emitTaskLedger(emit, request, goalTree);
            }
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
            await _taskScope.archiveLedgerForRequest(
              request,
              LedgerStatus.completed,
            );
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

        // The tool is now registry-validated, permission-checked, preflighted,
        // and cleared for execution. Only at this boundary is a specific
        // pre-action narrative truthful.
        final executeNarrative = selectNarrative.trim().isNotEmpty
            ? selectNarrative
            : NarrativeNarrator.narrateNext('executing', detectedLang.code);
        if (logger.logStreamBubble(
          kind: 'next_action',
          phase: 'select_tool',
          message: executeNarrative,
          evidenceRefs: [selectionEvidenceRef, 'tool:${toolRequest.name}'],
          contextPolicy: 'exclude',
        )) {
          emit(logger.events.last);
        }
        if (logger.logPreActionNarrative(
          'executing',
          NarrativeNarrator.narrateNext('executing', detectedLang.code),
        )) {
          emit(logger.events.last);
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
        final toolResultEvidenceRef = 'runtime_event:${logger.events.last.id}';

        final permissionFinal = permissionDeniedResponseFor(result);
        if (permissionFinal != null) {
          final actions = permissionDeniedActionsFor(result);
          // Mirror the pre-flight gate: park a resumable ledger so the recent
          // task (not a stale one) resumes once the permission is granted.
          if (request.source == RequestSource.chat &&
              goalTree.isNotEmpty &&
              !goalTree.isComplete) {
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
            _pendingActionsCallback?.call(
              request.agentId,
              PendingAction(
                toolName: toolRequest.name,
                toolArgs: toolRequest.args,
                userFacingSummary: permissionFinal,
                languageCode: detectedLang.code,
                resumeContext: {
                  'ledger_id': ledger.id,
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
                },
              ),
            );
          } else {
            await _taskScope.finishScopeForRequest(
              request,
              LedgerStatus.failed,
            );
          }
          logger.logFinalResponse(permissionFinal);
          return AgentRuntimeResponse(
            finalMessage: permissionFinal,
            success: false,
            state: AgentRuntimeState.failed,
            events: logger.events,
            actions: actions,
          );
        }

        if (!result.success && _isCapabilityBoundaryFailure(result)) {
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          final finalResponse = _capabilityBoundaryMessage(result);
          logger.logFinalResponse(finalResponse);
          return AgentRuntimeResponse(
            finalMessage: finalResponse,
            success: false,
            state: AgentRuntimeState.failed,
            events: logger.events,
          );
        }

        if (result.success) {
          _memory.purgeFailuresForTool(request.agentId, toolRequest.name);
        }
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
                  initialPreviousResults: previousResults,
                  initialStep: currentStep,
                );
              }
              await _taskScope.finishScopeForRequest(
                request,
                LedgerStatus.failed,
              );
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
            // A PRECURSOR tool (vm.status, vm.list_plugins, app.resolve) is a
            // pre-flight check that must be FOLLOWED by an action — it can
            // never complete an action subgoal on its own. Without this guard
            // a "create file + serve with bun" task ends right after vm.status:
            // status is retrieval + the last planned step, so the action
            // subgoal gets force-marked done and the serve command never runs.
            !_isPrecursorTool(toolRequest.name) &&
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
            shortCircuitActive.notes ??= 'retrieval_completed';
          }
          final verificationBlocker = await _completionVerifier
              .blockIfUnverified(
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
          if (goalTree.isNotEmpty && goalTree.isComplete) {
            _emitTaskLedger(emit, request, goalTree);
          }
          if (logger.logPreActionNarrative(
            'composing',
            NarrativeNarrator.narrateNext('composing', detectedLang.code),
          )) {
            emit(logger.events.last);
          }
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
          await _taskScope.archiveLedgerForRequest(
            request,
            LedgerStatus.completed,
          );
          return AgentRuntimeResponse(
            finalMessage: localFinal,
            success: true,
            state: AgentRuntimeState.done,
            events: logger.events,
            actions: result.actions,
          );
        }

        // Review result.
        state = AgentRuntimeState.reviewing;
        logger.logStateChange(state, 'Reviewing tool result');
        emit(logger.events.last);
        if (logger.logPreActionNarrative(
          'reviewing',
          NarrativeNarrator.narrateNext('reviewing', detectedLang.code),
        )) {
          emit(logger.events.last);
        }

        final review = await executor.review(
          result: result,
          plan: plan,
          currentStep: currentStep,
          userMessage: request.userMessage,
          logger: logger,
          previousResults: previousResults,
          language: detectedLang.label,
          goalTree: goalTree,
          recentMessages: loopRecentMsgs,
          agentName: request.agentName.isNotEmpty
              ? request.agentName
              : request.agentId,
          agentId: request.agentId,
        );
        emit(logger.events.last);

        var reviewStatus = review?['status'] as String? ?? '';
        final reportedReviewStatus = reviewStatus;
        // A failed tool can never finalize as "done" — the action did not
        // happen. Force the reviewer's hand: ask the user only when there is
        // genuine ambiguity the loop can't resolve.
        //
        // status="continue" after a failure is intentionally allowed through:
        // it is the self-heal signal the reviewer emits when it sees a
        // recoverable cause (missing precondition, missing toolchain, transient
        // blip) and has a corrective next step in mind. Forcing it to
        // ask_user/failed here destroys that decision and turns a recoverable
        // failure into an aborted task. Existing safety nets (StuckDetector,
        // RecoveryCoordinator.maxAttempts, adaptiveLimit) already bound any
        // false-positive continue loop.
        if (!result.success && reviewStatus == 'done') {
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
            review?['final_response'] ??= _emptyResultMessage(toolRequest.name);
          }
        }

        if (review != null) {
          final rawReviewNarrative = (review['narrative'] ?? '').toString();
          final reviewNarrative = NarrativeNarrator.gate(
            llmNarrative: rawReviewNarrative,
            decision: reviewStatus,
            languageCode: detectedLang.code,
          );
          if (reviewNarrative != rawReviewNarrative &&
              rawReviewNarrative.isNotEmpty) {
            logger.logDivergence('narrative_gate_override', {
              'phase': 'review',
              'decision': reviewStatus,
            });
          }
          final milestoneNarrative =
              !result.success &&
                  reportedReviewStatus != 'done' &&
                  rawReviewNarrative.trim().isNotEmpty
              ? rawReviewNarrative
              : reviewNarrative;
          if (milestoneNarrative.isNotEmpty &&
              logger.logStreamBubble(
                kind: result.success ? 'tool_insight' : 'tool_failure',
                phase: 'review',
                message: milestoneNarrative,
                evidenceRefs: [
                  toolResultEvidenceRef,
                  'tool:${toolRequest.name}',
                ],
                contextPolicy: result.success ? 'include' : 'exclude',
              )) {
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
              resultRef: update['result_ref']?.toString(),
              notes: update['notes']?.toString(),
            );
            if (ok) {
              _emitTaskLedger(emit, request, goalTree);
            }
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

          // State invalidation: reviewer can revert earlier "done" subgoals
          // back to in_progress when live tool data contradicts their
          // precondition (e.g. app_agent.inspect shows a different package
          // than the target the prior subgoal claimed to open).
          final batch = review['subgoal_updates'];
          if (batch is List && batch.isNotEmpty) {
            var anyApplied = false;
            for (final entry in batch) {
              if (entry is! Map) continue;
              final id = (entry['id'] ?? '').toString();
              if (id.isEmpty) continue;
              final newStatus = SubgoalStatusX.fromLabel(
                entry['status'] as String?,
              );
              final applied = goalTree.applyStatusUpdate(
                subgoalId: id,
                status: newStatus,
                resultRef: entry['result_ref']?.toString(),
                notes: entry['notes']?.toString(),
              );
              if (applied) {
                anyApplied = true;
                logger.logStateChange(
                  state,
                  'Subgoal $id reverted to ${newStatus.label} by reviewer (live state mismatch).',
                );
                emit(logger.events.last);
              }
            }
            if (anyApplied) {
              _emitTaskLedger(emit, request, goalTree);
            }
          }
        }

        if (review == null) {
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          return fail(_runtimePhrase('runtime_review_failed'), logger);
        }

        if (reviewStatus == 'done') {
          // Setup-only guard: a corrective/precondition tool succeeding is
          // never the user's goal. If the just-succeeded tool is pure setup
          // (`mkdir`, bare `cd`, install, etc.) AND the original request
          // implies productive follow-up work that has not visibly run yet,
          // downgrade to continue so the next step re-attempts the real
          // action. This sits BEFORE the goalTree.isComplete guard because
          // a single coarse `sg_main` subgoal can be marked done by the
          // setup tool itself, which would otherwise let `done` slip past.
          if (result.success &&
              isSetupOnlyToolCall(toolRequest) &&
              userGoalImpliesProductiveWork(goalTree.mainGoal)) {
            logger.logDivergence('setup_only_done_overridden', {
              'tool': toolRequest.name,
              'command': (toolRequest.args['command'] ?? '').toString(),
              'step': currentStep,
            });
            logger.logError(
              'Reviewer returned done after a setup-only action '
              '(${toolRequest.name}). The corrective step is the means, not '
              'the goal — continuing so the original request runs.',
            );
            // Re-open the active subgoal so the next selectTool sees pending
            // work and the loop does not exit on the next iteration's review.
            final active = goalTree.nextActionable;
            if (active != null) {
              active.status = SubgoalStatus.inProgress;
            } else {
              for (final s in goalTree.subgoals) {
                if (s.status == SubgoalStatus.done) {
                  s.status = SubgoalStatus.inProgress;
                  break;
                }
              }
            }
            previousResults.add({
              'step': currentStep,
              'tool': toolRequest.name,
              'result': _shrinkResult(result.data),
              'note':
                  'Setup-only tool succeeded; original action still pending.',
            });
            currentStep++;
            retryCount = 0;
            continue;
          }

          if (goalTree.isNotEmpty && !goalTree.isComplete) {
            logger.logDivergence('premature_done_overridden', {
              'source': 'reviewer',
              'remaining_subgoals': goalTree.subgoals
                  .where((s) => !s.isTerminal)
                  .length,
              'step': currentStep,
            });
            logger.logError(
              'Reviewer tried to finish early. Goal tree still has '
              '${goalTree.subgoals.where((s) => !s.isTerminal).length} subgoal(s) outstanding. Continuing.',
            );
            previousResults.add({
              'step': currentStep,
              'tool': toolRequest.name,
              'result': _shrinkResult(result.data),
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
              : review['final_response'] as String? ??
                    _runtimePhrase('runtime_task_completed');
          final verificationBlocker = await _completionVerifier
              .blockIfUnverified(
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
          // When the task ends on an answer/respond subgoal (e.g. "summarize the
          // posts and tell me here"), the REVIEWER's final_response IS the
          // synthesized answer — composed from everything it saw across the
          // whole flow. It MUST be the message the user sees.
          //
          // Critical: do NOT fall back to `finalResponse` here. For an app_agent
          // read flow the last tool is `app_agent.inspect` (a retrieval tool),
          // so `finalResponse` was built by answerFromToolResult against the RAW
          // accessibility node tree — which yields a generic recap, not the
          // summary. And taskSummary is label-only. Both drop the actual
          // content, leaving the user thinking it was "sent" when nothing
          // arrived. Use the reviewer's composed answer verbatim.
          //
          // Deterministic source first: system.rtb / chat.send put the EXACT
          // delivered text in result.data. That text was literally shown to the
          // user, so echoing it as the final reply can never be wrong.
          final deliveredContent = _extractDeliveredContent(
            result,
            previousResults,
          );
          final hasAnswerSubgoal = goalTree.subgoals.any(
            (s) => s.isTerminal && _isAnswerOnlySubgoal(s),
          );
          // A delivery subgoal (system.rtb / chat.send) carries the content the
          // user asked for but uses a delivery TOOL, not _operation=respond — so
          // _isAnswerOnlySubgoal misses it. Without this, a "summarize and send"
          // task finalizes to the label-only recap and the real summary is lost.
          final hasDeliverySubgoal = goalTree.subgoals.any(
            (s) => s.isTerminal && _isDeliverySubgoal(s),
          );
          final reviewAnswer = (review['final_response'] as String?)?.trim();
          final hasSubstantiveAnswer =
              reviewAnswer != null && reviewAnswer.length > 12;
          final completedFinal =
              (deliveredContent != null && deliveredContent.isNotEmpty)
              ? deliveredContent
              : ((hasAnswerSubgoal || hasDeliverySubgoal) &&
                    hasSubstantiveAnswer)
              ? reviewAnswer
              : (goalTree.isNotEmpty &&
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
                    : finalResponse);
          logger.logFinalResponse(completedFinal);
          await _taskScope.archiveLedgerForRequest(
            request,
            LedgerStatus.completed,
          );
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
              await _taskScope.finishScopeForRequest(
                request,
                LedgerStatus.failed,
              );
              return fail(_capabilityNotFoundMessage(), logger);
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
              initialPreviousResults: previousResults,
              initialStep: currentStep,
            );
          }
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          // Prefer the reviewer's specific, user-language explanation (it is
          // instructed to quote the exact stderr/cause and suggest a next
          // step). If the reviewer gave nothing concrete, fall back to the raw
          // cause pulled straight from the tool result before resorting to the
          // generic recovery phrase — a real stderr line is more useful to the
          // user than "I hit a technical issue".
          final reviewerDetail = (review['error'] as String?)?.trim() ?? '';
          final rawCause = extractFailureCause(result);
          final giveUp = reviewerDetail.isNotEmpty
              ? reviewerDetail
              : rawCause.isNotEmpty
              ? rawCause
              : (recovery?.giveUpMessage(_settingsLanguage()) ??
                    _runtimePhrase('runtime_unrecoverable_error'));
          return fail(giveUp, logger);
        }

        if (reviewStatus == 'retry' && retryCount < 1) {
          retryCount++;
          previousResults.add({
            'step': currentStep,
            'tool': toolRequest.name,
            'result': _shrinkResult(result.data),
            'retried': true,
          });
          continue;
        }

        previousResults.add({
          'step': currentStep,
          'tool': toolRequest.name,
          'result': _shrinkResult(result.data),
        });
        currentStep++;
        retryCount = 0;
      }
    }

    // Loop exhausted. Fast-path tasks emit a sentinel so the caller can retry
    // in normal mode without surfacing a failure to the user.
    if (fastPath) {
      logger.logStateChange(
        AgentRuntimeState.fastPathExhausted,
        'Fast-path exhausted at $adaptiveLimit iterations; caller will retry in normal mode',
      );
      emit(logger.events.last);
      return AgentRuntimeResponse(
        finalMessage: '',
        success: false,
        state: AgentRuntimeState.fastPathExhausted,
        events: logger.events,
        previousResults: previousResults,
        nextStep: currentStep,
      );
    }

    await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
    return fail(_runtimePhrase('runtime_max_steps'), logger);
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

  /// Extract a stable target identifier from tool args for semantic stuck
  /// detection. Returns the first present id/name-like field; empty when none
  /// (caller then falls back to full-arg matching). Generic across domains —
  /// covers the common id/name/target/path/package/url keys.
  static String _targetFromArgs(Map<String, dynamic> args) {
    const keys = [
      'id',
      'agent_id',
      'agentId',
      'name',
      'agent_name',
      'agentName',
      'target',
      'node_id',
      'nodeId',
      'path',
      'package',
      'url',
      'title',
      'query',
    ];
    for (final k in keys) {
      final v = args[k];
      if (v is String && v.trim().isNotEmpty) return '$k=${v.trim()}';
    }
    return '';
  }

  /// Compact a tool result before it is appended to [previousResults] and
  /// re-serialized into the selector prompt every iteration. Without this the
  /// accumulated context grows unbounded, inflating tokens and increasing the
  /// chance the model re-derives the same action/narrative. Long strings are
  /// truncated and long lists are capped — enough survives for the selector to
  /// reference IDs/names, but the prompt stays bounded.
  static Map<String, dynamic>? _shrinkResult(Map<String, dynamic>? data) {
    if (data == null) return null;
    final out = <String, dynamic>{};
    data.forEach((k, v) {
      if (v is String && v.length > 600) {
        out[k] = '${v.substring(0, 600)}…(+${v.length - 600} chars)';
      } else if (v is List && _isNodeTree(v)) {
        // app_agent.inspect screen node tree. The selector picks a node_id from
        // THIS list, so a blind 10-item cap blinds it to expand affordances
        // ("see more"/"lainnya") and to later posts — the exact reason the agent
        // could only scroll instead of clicking. Keep ACTIONABLE + content nodes
        // (compacted to the fields needed to choose an action) up to a higher
        // cap; drop only inert structural/empty nodes.
        out[k] = _compactNodeTree(v);
      } else if (v is List && v.length > 10) {
        out[k] = [...v.take(10), '…(+${v.length - 10} more)'];
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  /// True when [list] looks like an accessibility node tree (maps carrying an
  /// `id` plus interaction flags) rather than an ordinary data list.
  static bool _isNodeTree(List<dynamic> list) {
    if (list.isEmpty) return false;
    final first = list.first;
    return first is Map &&
        first.containsKey('id') &&
        (first.containsKey('clickable') ||
            first.containsKey('editable') ||
            first.containsKey('scrollable'));
  }

  /// Compact a node tree for the selector prompt: keep nodes that are
  /// actionable (clickable/editable/scrollable) OR carry content (text/desc),
  /// project each to the fields the selector actually needs to choose a target,
  /// and bound the total. Inert empty structural nodes are dropped. This keeps
  /// expand affordances and post content visible without exploding tokens.
  static List<dynamic> _compactNodeTree(List<dynamic> nodes) {
    const maxNodes = 45;
    final kept = <Map<String, dynamic>>[];
    for (final n in nodes) {
      if (n is! Map) continue;
      final text = (n['text'] ?? '').toString().trim();
      final desc = (n['desc'] ?? '').toString().trim();
      final clickable = n['clickable'] == true;
      final editable = n['editable'] == true;
      final scrollable = n['scrollable'] == true;
      final hasContent = text.isNotEmpty || desc.isNotEmpty;
      final actionable = clickable || editable || scrollable;
      if (!hasContent && !actionable) continue; // drop inert structural nodes
      kept.add({
        'id': n['id'],
        if (text.isNotEmpty)
          'text': text.length > 400 ? '${text.substring(0, 400)}…' : text,
        if (desc.isNotEmpty)
          'desc': desc.length > 200 ? '${desc.substring(0, 200)}…' : desc,
        if (clickable) 'clickable': true,
        if (editable) 'editable': true,
        if (scrollable) 'scrollable': true,
      });
      if (kept.length >= maxNodes) {
        kept.add({'_truncated': 'more nodes off-screen; scroll to reveal'});
        break;
      }
    }
    return kept;
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
    // A precursor (pre-flight) tool result is never the final answer — it must
    // be followed by the action it gates.
    if (_isPrecursorTool(toolName)) return false;
    return _isRetrievalTool(toolName);
  }

  /// Tools that are PRE-FLIGHT checks gating a later action, never an outcome
  /// on their own. Their own descriptions say "use this BEFORE …". Treating a
  /// precursor result as task completion strands the real action (e.g. ending
  /// after `vm.status` without ever running `vm.run_command`).
  static bool _isPrecursorTool(String toolName) {
    const precursors = {'vm.status', 'vm.list_plugins', 'app.resolve'};
    return precursors.contains(toolName.toLowerCase());
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
    if (reason == ToolPermissionBlockReason.moduleMissing.name) {
      return LanguageRegistry.phrase('permission_module_missing', code, {
        'module': module,
        'action': actionLabel,
      });
    }

    if (setting.isNotEmpty) {
      return LanguageRegistry.phrase('permission_denied', code, {
        'module': module,
        'setting': setting,
        'action': actionLabel,
      });
    }

    return LanguageRegistry.phrase('permission_denied_no_setting', code, {
      'module': module,
      'action': actionLabel,
      'reason': reason,
    });
  }

  /// Action buttons for ecosystem failures such as missing/disabled modules.
  List<ResultAction> permissionDeniedActionsFor(ToolExecutionResult result) {
    final data = result.data;
    if (data == null ||
        data['errorCode'] != ToolPermissionPolicy.permissionDeniedCode) {
      return const [];
    }

    final moduleId = (data['moduleId'] as String? ?? '').trim();
    if (moduleId.isEmpty) return const [];

    final code = _languageCode;
    final moduleName = (data['moduleName'] as String? ?? '').trim();
    final module = moduleName.isEmpty ? moduleId : moduleName;
    final reason = data['reason'] as String? ?? '';

    if (reason == ToolPermissionBlockReason.moduleMissing.name) {
      return [
        ResultAction(
          label: LanguageRegistry.phrase('action_install_module', code, {
            'module': module,
          }),
          icon: 'add_rounded',
          type: 'install_module',
          target: moduleId,
          params: {'moduleId': moduleId},
        ),
      ];
    }

    return [
      ResultAction(
        label: LanguageRegistry.phrase('action_open_module', code, {
          'module': module,
        }),
        icon: 'extension_rounded',
        type: 'navigate',
        target: '/modules/$moduleId',
        params: {'moduleId': moduleId},
      ),
    ];
  }

  /// Synthesize a final response from accumulated results when the selector
  /// oscillates and cannot converge. Mirrors the completed-tree path but does
  /// not require a live tool result (we are in the select branch).
  Future<AgentRuntimeResponse> _finishFromResults({
    required AgentRuntimeRequest request,
    required List<Map<String, dynamic>> previousResults,
    required GoalTree goalTree,
    required ToolVerbalizer verbalizer,
    required DetectedLanguage detectedLang,
    required RuntimeLogger logger,
    required void Function(RuntimeEvent) emit,
  }) async {
    final terminalSubgoals = goalTree.isEmpty
        ? const <Subgoal>[]
        : goalTree.subgoals
              .where(
                (s) =>
                    s.status == SubgoalStatus.done ||
                    s.status == SubgoalStatus.failed ||
                    s.status == SubgoalStatus.skipped,
              )
              .toList(growable: false);
    final finalMsg = terminalSubgoals.isNotEmpty
        ? await verbalizer.taskSummary(
            mainGoal: goalTree.mainGoal,
            completedSubgoals: terminalSubgoals
                .map((s) => _subgoalToSummary(s))
                .toList(growable: false),
            language: detectedLang,
          )
        : await verbalizer.abort(
            reason: 'selector could not converge on a final answer',
            language: detectedLang,
          );
    logger.logFinalResponse(finalMsg);
    await _taskScope.archiveLedgerForRequest(request, LedgerStatus.completed);
    return AgentRuntimeResponse(
      finalMessage: finalMsg,
      success: terminalSubgoals.isNotEmpty,
      state: terminalSubgoals.isNotEmpty
          ? AgentRuntimeState.done
          : AgentRuntimeState.failed,
      events: logger.events,
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

  void _emitTaskLedger(
    void Function(RuntimeEvent) emit,
    AgentRuntimeRequest request,
    GoalTree goalTree,
  ) {
    if (request.source != RequestSource.chat || goalTree.subgoals.length < 2) {
      return;
    }
    final ledger = TaskLedger(
      id: 'chat_live_${request.agentId}',
      agentId: request.agentId,
      source: LedgerSource.chat,
      mainGoal: goalTree.mainGoal,
      languageCode: _languageCode,
      originalUserMessage: request.userMessage,
      goalTree: goalTree,
      status: goalTree.isComplete
          ? LedgerStatus.completed
          : LedgerStatus.active,
    );
    emit(
      RuntimeEvent(
        type: 'task_ledger',
        message: 'Task ledger updated',
        data: {'ledger': ledger.toJson()},
      ),
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
      'results',
      'items',
      'events',
      'notes',
      'files',
      'matches',
      'apps',
      'recent',
      'list',
      'data',
      'slots',
      'conflicts',
      'tree',
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

  /// Pull the one-line cause out of a failed tool result so the user sees
  /// what actually went wrong instead of a polite generic abort. Returns the
  /// shortest non-empty signal among (in order): the result's first line of
  /// `error`, the first non-empty line of `data.stderr`, or `data.message`.
  ///
  /// Empty when the result is null/successful or has no extractable signal —
  /// callers fall back to their existing generic message in that case.
  ///
  /// Generic across modules: it does not look at tool name and never invents
  /// content; it only surfaces what the underlying handler already produced.
  static String extractFailureCause(ToolExecutionResult? result) {
    if (result == null || result.success) return '';
    final err = _firstLine(result.error ?? '');
    if (err.isNotEmpty) return err;
    return _causeFromDataMap(result.data);
  }

  /// Same extraction as [extractFailureCause] but over a shrunk `result.data`
  /// map stored in `previousResults` (which keeps `success`/`stderr`/`message`
  /// but drops the top-level `error`). Scans the history backward and returns
  /// the cause of the most recent failed entry; empty when none is found.
  static String _lastFailureCauseFrom(List<Map<String, dynamic>> history) {
    for (var i = history.length - 1; i >= 0; i--) {
      final data = history[i]['result'];
      if (data is! Map) continue;
      if (data['success'] == false) {
        final cause = _causeFromDataMap(data.cast<String, dynamic>());
        if (cause.isNotEmpty) return cause;
      }
    }
    return '';
  }

  /// Shared cause extraction over a tool-result `data` map.
  static String _causeFromDataMap(Map<String, dynamic>? data) {
    if (data == null) return '';
    final stderr = _firstLine((data['stderr'] ?? '').toString());
    if (stderr.isNotEmpty) return stderr;
    return _firstLine((data['message'] ?? '').toString());
  }

  /// First non-empty trimmed line of [raw]; empty string when blank.
  static String _firstLine(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final nl = trimmed.indexOf('\n');
    final line = nl == -1 ? trimmed : trimmed.substring(0, nl);
    return line.trim();
  }

  /// True when the tool call is a pure setup / precondition-fixing action —
  /// one whose success establishes a prerequisite for the real work but is
  /// NEVER itself the user's goal. A shell command that only creates a
  /// directory, installs/updates a package, or checks status falls here.
  ///
  /// Used to stop a corrective step (e.g. `mkdir -p <dir>` issued to recover
  /// from a "No such file or directory" failure) from being mistaken for task
  /// completion. The fix is the means, not the end — the original action that
  /// triggered it still has to run.
  static bool isSetupOnlyToolCall(ToolCallRequest tool) {
    // Status/lookup tools are setup-ish but handled elsewhere; focus on the
    // shell path where a corrective command can masquerade as the goal.
    if (tool.name != 'vm.run_command') return false;
    final command = (tool.args['command'] ?? '').toString().trim();
    if (command.isEmpty) return false;

    // A compound command that chains a corrective prefix into the real action
    // (`mkdir -p x && npm create ...`) is NOT setup-only — the productive part
    // runs in the same call. Only a bare corrective command counts.
    final segments = command
        .split(RegExp(r'&&|\|\||;'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty) return false;

    return segments.every(_isCorrectiveSegment);
  }

  /// True when a single shell segment only prepares the environment.
  static bool _isCorrectiveSegment(String segment) {
    // Leading first token (the program), lowercased.
    final head = segment.split(RegExp(r'\s+')).first.toLowerCase();
    const correctiveHeads = {
      'mkdir',
      'cd',
      'touch',
      'chmod',
      'chown',
      'export',
      'mount',
      'ln',
    };
    if (correctiveHeads.contains(head)) return true;
    // Package-manager install/update prep, e.g. `apt-get install`, `npm i`.
    final installer = RegExp(
      r'^(apt|apt-get|pkg|pip|pip3|npm|pnpm|yarn|bun)\b.*\b(install|add|update|upgrade|i)\b',
    );
    return installer.hasMatch(segment.toLowerCase());
  }

  /// True when the user's request implies productive work beyond mere setup —
  /// i.e. the goal is NOT satisfied by creating a directory or installing a
  /// prerequisite alone. Gates the setup-only done guard so a genuine
  /// "just make a folder for me" request still finalizes normally.
  ///
  /// Operates on [mainGoal] only (the analyzer normalizes user intent into
  /// English on the way in — see PromptAnalyze) so the keyword list stays
  /// language-agnostic. Conservative by design: returns true only when a
  /// productive verb/noun is present in the normalized goal. When unsure,
  /// returns false (trust the reviewer's `done`).
  static bool userGoalImpliesProductiveWork(String mainGoal) {
    final haystack = mainGoal.toLowerCase().trim();
    if (haystack.isEmpty) return false;

    // Productive intent markers — verbs/nouns that bare mkdir/install can
    // never satisfy. English only; the analyzer normalizes goal text upstream.
    const productiveMarkers = [
      'serve',
      'server',
      'run ',
      'start',
      'build',
      'scaffold',
      'create app',
      'create project',
      'landing page',
      'website',
      'web app',
      'deploy',
      'compile',
      'write ',
      'generate',
      'render',
      'dev server',
    ];
    final hasProductive = productiveMarkers.any(haystack.contains);
    if (!hasProductive) return false;

    // If the ENTIRE goal is literally just "make a directory/folder", do not
    // override even if a stray marker matched.
    final onlyFolder = RegExp(
      r'^\s*(create|make)\s+(a\s+)?(folder|directory|dir)\b',
    ).hasMatch(haystack);
    return !onlyFolder;
  }

  /// User-facing message when no tool exists for the requested action.
  String _runtimePhrase(String key, [Map<String, String> params = const {}]) =>
      LanguageRegistry.phrase(key, _languageCode, params);

  DetectedLanguage _settingsLanguage() =>
      DetectedLanguage.fromAnalyzerCode(_languageCode);

  String _capabilityNotFoundMessage() =>
      _runtimePhrase('runtime_capability_not_found');

  String _capabilityBoundaryMessage(ToolExecutionResult result) {
    final messageKey = result.data?['messageKey']?.toString().trim();
    if (messageKey != null && messageKey.isNotEmpty) {
      return _runtimePhrase(messageKey);
    }

    final error = (result.error ?? '').trim();
    if (error.isNotEmpty) return error;
    return _capabilityNotFoundMessage();
  }

  /// Localized "no results" reply when the empty-result loop guard fires.
  static String emptyResultMessage(String langCode, String toolName) {
    final key = _emptyResultPhraseKey(toolName);
    return LanguageRegistry.phrase(key, langCode);
  }

  static String _emptyResultPhraseKey(String toolName) {
    final isFiles = toolName.startsWith('files.');
    final isNotes = toolName.startsWith('notes.');
    final isCal = toolName.startsWith('calendar.');
    if (isFiles) return 'runtime_empty_files';
    if (isNotes) return 'runtime_empty_notes';
    if (isCal) return 'runtime_empty_calendar';
    return 'runtime_empty_results';
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
        name == 'system.config.read' ||
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

  /// A terminal DELIVERY subgoal carries the content the user asked for but uses
  /// a delivery TOOL (system.rtb / chat.send) rather than an `_operation=respond`
  /// verb — so [_isAnswerOnlySubgoal] misses it. Used at finalize so a
  /// "summarize and send" task surfaces the real content, not a label recap.
  bool _isDeliverySubgoal(Subgoal subgoal) {
    final tool = _subgoalSlot(subgoal, const [
      'tool',
      'tool_name',
    ]).toLowerCase();
    return tool == 'system.rtb' || tool == 'chat.send';
  }

  /// Pull the literal user-facing text already delivered by `system.rtb` (which
  /// puts the message in `data.pending_chat_message` with `message_delivered`).
  /// This is the exact text shown to the user, so echoing it as the final reply
  /// can never be wrong. Checks the live result first, then the most recent
  /// delivery in [previousResults]. Returns null when nothing was delivered.
  ///
  /// Note: `chat.send` does NOT carry its body in the result (only ids/length),
  /// so it is not recoverable here — those flows fall back to the reviewer's
  /// composed answer via the `hasDeliverySubgoal` gate.
  String? _extractDeliveredContent(
    ToolExecutionResult result,
    List<Map<String, dynamic>> previousResults,
  ) {
    String? fromData(Map? data) {
      if (data == null) return null;
      if (data['message_delivered'] == true) {
        final m = (data['pending_chat_message'] ?? '').toString().trim();
        if (m.isNotEmpty) return m;
      }
      return null;
    }

    final live = fromData(result.data);
    if (live != null) return live;
    for (final entry in previousResults.reversed) {
      final inner = entry['result'];
      if (inner is Map) {
        final v = fromData(inner);
        if (v != null) return v;
      }
    }
    return null;
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

  String _emptyResultMessage(String toolName) {
    return LanguageRegistry.phrase(
      _emptyResultPhraseKey(toolName),
      _languageCode,
    );
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
    final failureKind = result.data?['failureKind']?.toString().toLowerCase();
    if (failureKind == 'capability_boundary') {
      return true;
    }
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
