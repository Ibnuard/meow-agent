import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/agent_runtime/runtime_engine.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import '../../agents/data/agent_repository.dart';
import '../../chat/data/chat_history_service.dart';
import '../../chat/data/unread_service.dart';
import '../../providers/data/provider_repository.dart';
import 'workflow_builtin_vars.dart';
import 'workflow_foreground_service.dart';
import 'workflow_model.dart';
import 'workflow_notification_service.dart';
import 'workflow_scheduler.dart';
import 'workflow_repository.dart';

/// Runs in the main isolate. Uses dynamic scheduling to check for due workflows
/// and executes them via RuntimeEngine with priority queue ordering.
class WorkflowRunner {
  WorkflowRunner(this._ref);

  final Ref _ref;
  final WorkflowRepository _repo = WorkflowRepository();
  Timer? _timer;
  final Set<String> _runningWorkflows = {};

  /// Minimum timeout per step in seconds. Any workflow — new or legacy —
  /// will be raised to this floor at runtime. Complex thinking models often
  /// need 2-5 minutes per step; a 5-minute floor prevents premature timeouts
  /// without requiring a database migration of stored values.
  static const _minStepTimeoutSeconds = 300;

  /// Enforce minimum floor on step timeout.
  static int _effectiveTimeout(int stored) =>
      stored < _minStepTimeoutSeconds ? _minStepTimeoutSeconds : stored;

  /// Priority-ordered execution queue. Each entry pairs a workflow with the
  /// optional trigger context that fired it (e.g. notification metadata).
  final Queue<_QueuedWorkflow> _executionQueue = Queue();
  bool _processingQueue = false;

  /// Start the dynamic scheduler.
  void start() {
    _timer?.cancel();
    _scheduleNextCheck();
    // Also run immediately on start.
    _checkAndRun();
  }

  /// Stop the runner.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _executionQueue.clear();
  }

  /// Dynamic scheduling: calculate time until next due workflow.
  Future<void> _scheduleNextCheck() async {
    _timer?.cancel();

    // Calculate optimal check interval based on next due workflow.
    final workflows = await _repo.listEnabledByPriority();
    final nextFire = WorkflowScheduler.timeUntilNextFire(workflows);

    // Clamp between 10 seconds and 60 seconds.
    const minInterval = Duration(seconds: 10);
    const maxInterval = Duration(seconds: 60);
    Duration interval = maxInterval;

    if (nextFire != null) {
      // Check slightly before the workflow is due.
      final adjusted = nextFire - const Duration(seconds: 5);
      if (adjusted < minInterval) {
        interval = minInterval;
      } else if (adjusted < maxInterval) {
        interval = adjusted;
      }
    }

    _timer = Timer(interval, () {
      _checkAndRun();
      _scheduleNextCheck();
    });
  }

  /// Check all enabled workflows and enqueue any that are due.
  Future<void> _checkAndRun() async {
    final workflows = await _repo.listEnabledByPriority();
    final now = DateTime.now();

    for (final wf in workflows) {
      if (_runningWorkflows.contains(wf.id)) continue;
      // Skip event-triggered workflows — they are fired by WorkflowEventListener.
      if (wf.trigger.type == TriggerType.event) continue;

      final due = _isDue(wf, now);
      if (!due) continue;

      // Mark this occurrence as claimed.
      await _repo.updateLastRun(
        wf.id,
        lastRun: now,
        lastResult: wf.lastResult ?? 'QUEUED',
        retryCount: wf.retryCount,
      );

      _enqueue(_QueuedWorkflow(wf.copyWith(lastRun: now), const {}));
    }
  }

  /// Enqueue a workflow for execution (used by both scheduler and event listener).
  ///
  /// [triggerVars] is an optional map of trigger-derived variables exposed to
  /// the prompt as `{{notif}}`, `{{notif_title}}`, etc. when the trigger is a
  /// notification keyword event. Pass null/empty for scheduled triggers.
  void enqueue(WorkflowModel wf, {Map<String, String>? triggerVars}) =>
      _enqueue(_QueuedWorkflow(wf, triggerVars ?? const {}));

  void _enqueue(_QueuedWorkflow item) {
    final wf = item.workflow;
    // Insert into queue based on priority.
    if (_executionQueue.isEmpty ||
        wf.priority.index <= _executionQueue.first.workflow.priority.index) {
      _executionQueue.addFirst(item);
    } else {
      _executionQueue.addLast(item);
    }
    _processQueue();
  }

  /// Process the execution queue sequentially.
  Future<void> _processQueue() async {
    if (_processingQueue) return;
    _processingQueue = true;

    try {
      while (_executionQueue.isNotEmpty) {
        final item = _executionQueue.removeFirst();
        final wf = item.workflow;
        if (_runningWorkflows.contains(wf.id)) continue;

        _runningWorkflows.add(wf.id);
        await WorkflowForegroundService.start(workflowTitle: wf.title);
        try {
          await _executeWorkflow(wf, item.triggerVars);
        } finally {
          _runningWorkflows.remove(wf.id);
          await WorkflowForegroundService.onWorkflowComplete();
        }
      }
    } finally {
      _processingQueue = false;
    }
  }

  /// Check if a workflow is due to run now.
  bool _isDue(WorkflowModel wf, DateTime now) {
    if (wf.trigger.type == TriggerType.interval) {
      if (wf.lastRun == null) return true;
      final elapsed = now.difference(wf.lastRun!).inSeconds;
      return elapsed >= (wf.trigger.intervalMinutes ?? 60) * 60;
    }

    // Schedule: check if current time matches trigger time.
    final hour = wf.trigger.hour ?? 0;
    final minute = wf.trigger.minute ?? 0;

    // Today's scheduled occurrence.
    final triggerToday = DateTime(now.year, now.month, now.day, hour, minute);

    // Only fire within a 90-second window starting at the trigger time.
    final delta = now.difference(triggerToday);
    if (delta.isNegative || delta.inSeconds > 90) {
      return false;
    }

    // Check day of week.
    if (wf.trigger.daysOfWeek != null && wf.trigger.daysOfWeek!.isNotEmpty) {
      if (!wf.trigger.daysOfWeek!.contains(now.weekday)) return false;
    }

    // Already executed/claimed today's occurrence? Skip until tomorrow.
    if (wf.lastRun != null) {
      final lr = wf.lastRun!;
      final alreadyClaimedThisOccurrence =
          lr.year == triggerToday.year &&
          lr.month == triggerToday.month &&
          lr.day == triggerToday.day &&
          !lr.isBefore(triggerToday) &&
          lr.difference(triggerToday).inMinutes < 10;
      if (alreadyClaimedThisOccurrence) return false;
    }

    return true;
  }

  /// Execute a workflow — handles both single-step and chained modes.
  ///
  /// [triggerVars] are variables derived from the trigger context (e.g.
  /// notification metadata) and override workflow-defined variables when keys
  /// collide. Empty for scheduled/interval triggers.
  Future<void> _executeWorkflow(
    WorkflowModel wf,
    Map<String, String> triggerVars,
  ) async {
    final stopwatch = Stopwatch()..start();
    final notifId = wf.id.hashCode.abs() % 2147483647;
    final capturedEvents = <WorkflowExecutionEvent>[];

    // Foreground service notification is already shown by _processQueue().
    // No separate "running" notification needed here — avoids double notif.

    try {
      final engine = _ref.read(agentRuntimeEngineProvider);
      final agents = _ref.read(agentListProvider);
      final providerRepo = _ref.read(providerRepositoryProvider);
      final providers = await providerRepo.loadAll();

      final agent = agents.where((a) => a.id == wf.agentId).firstOrNull;
      if (agent == null) {
        await _handleFailure(
          wf,
          'Agent tidak ditemukan: ${wf.agentId}',
          0,
          capturedEvents,
        );
        return;
      }
      final provider = providers
          .where((p) => p.id == agent.providerId)
          .firstOrNull;
      if (provider == null) {
        await _handleFailure(
          wf,
          'Provider LLM "${agent.providerId}" tidak ditemukan untuk agent "${agent.name}".',
          0,
          capturedEvents,
        );
        return;
      }

      if (wf.isChained) {
        // ─── Chained Workflow Execution ─────────────────────────────────────
        await _executeChained(
          wf,
          engine,
          providers,
          agents,
          agent,
          capturedEvents,
          stopwatch,
          notifId,
          triggerVars,
        );
      } else {
        // ─── Single-Step Execution ──────────────────────────────────────────
        await _executeSingle(
          wf,
          engine,
          provider,
          agent,
          capturedEvents,
          stopwatch,
          notifId,
          triggerVars,
        );
      }
    } on TimeoutException {
      stopwatch.stop();
      await _handleFailure(
        wf,
        'Timeout: eksekusi melebihi ${_effectiveTimeout(wf.timeoutSeconds)} detik.',
        stopwatch.elapsedMilliseconds,
        capturedEvents,
      );
    } catch (e, st) {
      stopwatch.stop();
      // ignore: avoid_print
      print('[WorkflowRunner] ${wf.title} error: $e\n$st');
      await _handleFailure(
        wf,
        'Error: $e',
        stopwatch.elapsedMilliseconds,
        capturedEvents,
      );
    }
  }

  /// Execute a single-step workflow.
  Future<void> _executeSingle(
    WorkflowModel wf,
    AgentRuntimeEngine engine,
    dynamic provider,
    dynamic agent,
    List<WorkflowExecutionEvent> capturedEvents,
    Stopwatch stopwatch,
    int notifId,
    Map<String, String> triggerVars,
  ) async {
    // Build the full variable map: legacy custom vars (if any), then
    // built-ins (time/identity/trigger). Built-ins win to avoid stale data.
    final builtIns = await WorkflowBuiltInVars.resolve(
      agentName: agent.name,
      agentId: wf.agentId,
      now: DateTime.now(),
      triggerVars: triggerVars,
    );
    final vars = <String, String>{}
      ..addAll(wf.variables) // legacy fallback
      ..addAll(builtIns);
    // Avoid double-injecting trigger var content: if the prompt references
    // any trigger var (@notif, @notif_body, etc.), swap that value for a
    // reference marker. The actual content lives once in the
    // [TRIGGER CONTEXT] block appended below.
    final substituteVars = _maskTriggerVarReferences(
      prompt: wf.prompt,
      vars: vars,
      triggerVars: triggerVars,
    );
    final resolvedPrompt = WorkflowBuiltInVars.substitute(
      wf.prompt,
      substituteVars,
    );
    final prompt = _wrapWithTriggerContext(resolvedPrompt, triggerVars);

    final response = await engine
        .run(
          AgentRuntimeRequest(
            agentId: wf.agentId,
            agentName: agent.name,
            userMessage: prompt,
            source: RequestSource.workflow,
          ),
          provider: provider,
          autoApproveSensitive: wf.allowSensitive,
          onEvent: (event) {
            capturedEvents.add(
              WorkflowExecutionEvent(
                type: event.type,
                message: event.message,
                createdAt: event.createdAt,
              ),
            );
          },
        )
        .timeout(Duration(seconds: _effectiveTimeout(wf.timeoutSeconds)));

    stopwatch.stop();
    final result = response.finalMessage;

    await _repo.updateLastRun(
      wf.id,
      lastRun: DateTime.now(),
      lastResult: result,
      retryCount: 0,
    );

    await _repo.logExecution(
      WorkflowExecution(
        workflowId: wf.id,
        agentId: wf.agentId,
        workflowTitle: wf.title,
        status: response.success ? 'success' : 'failed',
        result: result,
        executedAt: DateTime.now(),
        durationMs: stopwatch.elapsedMilliseconds,
        events: List.unmodifiable(capturedEvents),
      ),
    );

    if (wf.notification.showResult) {
      await WorkflowNotificationService.cancel(notifId);
      await WorkflowNotificationService.show(
        id: notifId,
        title: response.success ? '✅ ${wf.title}' : '❌ ${wf.title}',
        body: result,
        style: wf.notification.style.name,
        payload: 'workflow:${wf.id}',
      );
    }

    if (wf.sendToChat) {
      await _injectToChat(
        wf.agentId,
        response.success
            ? '✅ Workflow **${wf.title}** berhasil dijalankan.'
            : '❌ Workflow **${wf.title}** gagal dijalankan.',
      );
    }
  }

  /// Execute a chained (multi-step) workflow.
  Future<void> _executeChained(
    WorkflowModel wf,
    AgentRuntimeEngine engine,
    List<dynamic> providers,
    List<dynamic> agents,
    dynamic fallbackAgent,
    List<WorkflowExecutionEvent> capturedEvents,
    Stopwatch stopwatch,
    int notifId,
    Map<String, String> triggerVars,
  ) async {
    final stepResults = <StepResult>[];
    String previousResult = '';
    bool chainFailed = false;

    // Built-in variables that don't depend on the running agent are computed
    // once. Per-step we'll re-resolve to refresh `{{chat_session}}` with the
    // step's specific agent and to override `{{prev}}` / `{{step_index}}`.
    final baseBuiltIns = await WorkflowBuiltInVars.resolve(
      agentName: fallbackAgent.name,
      agentId: fallbackAgent.id,
      now: DateTime.now(),
      triggerVars: triggerVars,
    );

    for (int i = 0; i < wf.steps.length; i++) {
      final step = wf.steps[i];
      final stepAgent = step.agentId == null
          ? fallbackAgent
          : agents.where((a) => a.id == step.agentId).firstOrNull;
      final stepProvider = stepAgent == null
          ? null
          : providers.where((p) => p.id == stepAgent.providerId).firstOrNull;

      if (stepAgent == null || stepProvider == null) {
        stepResults.add(
          StepResult(
            stepId: step.id,
            status: 'failed',
            result: stepAgent == null
                ? 'Agent tidak ditemukan untuk langkah ini.'
                : 'Provider tidak ditemukan untuk agent "${stepAgent.name}".',
          ),
        );
        capturedEvents.add(
          WorkflowExecutionEvent(
            type: 'step_failed',
            message:
                'Step ${i + 1} "${step.id}" failed: agent/provider not found.',
            createdAt: DateTime.now(),
          ),
        );
        chainFailed = true;
        break;
      }

      // Build per-step var map: legacy custom vars + base built-ins +
      // step-local extras. Order: built-ins win over legacy, step extras win
      // over built-ins.
      //
      // We re-resolve `{{chat_session}}` (per-agent reference) and
      // `{{chat_history}}` (recent message dump) against the STEP'S agent so
      // a chain that hops Mina -> Mars sees Mars's session/history, not
      // Mina's.
      final isFallbackAgent = stepAgent.id == fallbackAgent.id;
      final stepChatSession = isFallbackAgent
          ? (baseBuiltIns['chat_session'] ?? '')
          : WorkflowBuiltInVars.renderChatSessionRef(stepAgent.name);
      final stepChatHistory = isFallbackAgent
          ? (baseBuiltIns['chat_history'] ?? '')
          : await WorkflowBuiltInVars.resolveChatHistory(stepAgent.id);
      final runtimeVars = <String, String>{}
        ..addAll(wf.variables) // legacy fallback
        ..addAll(baseBuiltIns)
        ..['chat_session'] = stepChatSession
        ..['chat_history'] = stepChatHistory
        ..['prev'] = previousResult
        ..['step_index'] = i.toString();

      // Evaluate condition.
      if (step.condition != null && step.condition!.isNotEmpty) {
        if (!_evaluateCondition(step.condition!, previousResult, runtimeVars)) {
          stepResults.add(
            StepResult(
              stepId: step.id,
              status: 'skipped',
              result: 'Condition not met: ${step.condition}',
            ),
          );
          capturedEvents.add(
            WorkflowExecutionEvent(
              type: 'step_skipped',
              message: 'Step ${i + 1} "${step.id}" skipped: condition not met.',
              createdAt: DateTime.now(),
            ),
          );
          continue;
        }
      }

      // ─── Build the resolved step prompt ─────────────────────────────────
      //
      // Generic structure for chained steps:
      //
      //   [WORKFLOW CONTEXT]   ← tells the runtime it already has data
      //   [USER INSTRUCTION]   ← user prompt with @prev swapped for a
      //                          reference marker (no duplicated content)
      //   [PREVIOUS STEP OUTPUT] ← single authoritative copy of prev
      //
      // The marker swap is the key fix: substituting @prev with the full
      // prev content AND attaching it as a separate block double-injects the
      // data into the prompt. The analyzer/selector then keys on whatever
      // domain the prev content happens to mention (e.g. "WhatsApp", "notif")
      // and picks the wrong tool family.
      final substituteVars = Map<String, String>.from(runtimeVars);
      final referencesPrev =
          RegExp(r'(?<![\w@])@prev\b').hasMatch(step.prompt) ||
          step.prompt.contains('{{prev}}');
      if (referencesPrev && i > 0) {
        substituteVars['prev'] =
            '<the previous step output — provided as the most recent '
            'assistant message in the conversation history>';
      }
      // Step 0 also has trigger-var content double-injection risk — mask
      // any trigger var the prompt references so its content lives once,
      // in the [TRIGGER CONTEXT] block. Same fix shape as @prev above.
      if (i == 0) {
        substituteVars.addAll(
          _maskTriggerVarReferences(
            prompt: step.prompt,
            vars: substituteVars,
            triggerVars: triggerVars,
            // Only override the specific keys we mask; preserve everything
            // else from runtimeVars.
            onlyKeysReferenced: true,
          ),
        );
      }

      var rawPrompt = WorkflowBuiltInVars.substitute(
        step.prompt,
        substituteVars,
      );

      if (i == 0) {
        rawPrompt = _wrapWithTriggerContext(rawPrompt, triggerVars);
      }

      // Compose request for the runtime engine. For step ≥ 2 we deliver
      // the previous step output as a CONVERSATION TURN (assistant role)
      // rather than mashing it into userMessage. This keeps the analyzer's
      // intent classification focused on the actual instruction ("kirim ke
      // chat") instead of the prev payload's keywords ("WhatsApp", "notif",
      // "shopping list") that would otherwise mis-route to fetchers like
      // notification.read_recent or notes.search.
      String stepUserMessage;
      List<ChatMessage> stepRecentMessages = const [];

      if (i == 0) {
        stepUserMessage = rawPrompt;
      } else if (previousResult.isEmpty) {
        stepUserMessage = rawPrompt;
      } else {
        stepUserMessage = _buildChainedUserMessage(
          stepIndex: i,
          totalSteps: wf.steps.length,
          userInstruction: rawPrompt,
        );
        stepRecentMessages = [
          ChatMessage(role: 'user', content: _previousStepInstructionMarker(i)),
          ChatMessage(role: 'assistant', content: previousResult),
        ];

        // Observability: record the EXACT previous-step output handed to this
        // step as conversation history. Lets the user verify whether step N
        // received correct data vs. hallucinated — without this, a wrong
        // result is indistinguishable from a bad handoff.
        final preview = previousResult.length > 500
            ? '${previousResult.substring(0, 500)}… (${previousResult.length} chars total)'
            : previousResult;
        capturedEvents.add(
          WorkflowExecutionEvent(
            type: 'step_handoff',
            message:
                '[Step ${i + 1}] Received from step $i (prev, '
                '${previousResult.length} chars):\n$preview',
            createdAt: DateTime.now(),
          ),
        );
      }

      capturedEvents.add(
        WorkflowExecutionEvent(
          type: 'step_start',
          message: 'Starting step ${i + 1}: ${step.id} (${stepAgent.name})',
          createdAt: DateTime.now(),
        ),
      );

      final stepStopwatch = Stopwatch()..start();

      try {
        final response = await engine
            .run(
              AgentRuntimeRequest(
                agentId: stepAgent.id,
                agentName: stepAgent.name,
                userMessage: stepUserMessage,
                recentMessages: stepRecentMessages,
                source: RequestSource.workflow,
              ),
              provider: stepProvider,
              autoApproveSensitive: wf.allowSensitive,
              onEvent: (event) {
                capturedEvents.add(
                  WorkflowExecutionEvent(
                    type: event.type,
                    message: '[Step ${i + 1}] ${event.message}',
                    createdAt: event.createdAt,
                  ),
                );
              },
            )
            .timeout(Duration(seconds: _effectiveTimeout(step.timeoutSeconds)));

        stepStopwatch.stop();
        previousResult = response.finalMessage;
        runtimeVars['step_${step.id}_result'] = previousResult;

        stepResults.add(
          StepResult(
            stepId: step.id,
            status: response.success ? 'success' : 'failed',
            result: previousResult,
            durationMs: stepStopwatch.elapsedMilliseconds,
          ),
        );

        if (!response.success) {
          switch (step.onFailure) {
            case StepFailureAction.stop:
              chainFailed = true;
              capturedEvents.add(
                WorkflowExecutionEvent(
                  type: 'chain_stopped',
                  message: 'Chain stopped at step ${i + 1} due to failure.',
                  createdAt: DateTime.now(),
                ),
              );
              break;
            case StepFailureAction.skip:
              capturedEvents.add(
                WorkflowExecutionEvent(
                  type: 'step_failure_skipped',
                  message: 'Step ${i + 1} failed but continuing (skip policy).',
                  createdAt: DateTime.now(),
                ),
              );
              break;
            case StepFailureAction.retry:
              // Retry once.
              capturedEvents.add(
                WorkflowExecutionEvent(
                  type: 'step_retry',
                  message: 'Retrying step ${i + 1}...',
                  createdAt: DateTime.now(),
                ),
              );
              final retryResponse = await engine
                  .run(
                    AgentRuntimeRequest(
                      agentId: stepAgent.id,
                      agentName: stepAgent.name,
                      userMessage: stepUserMessage,
                      recentMessages: stepRecentMessages,
                      source: RequestSource.workflow,
                    ),
                    provider: stepProvider,
                    autoApproveSensitive: wf.allowSensitive,
                    onEvent: (event) {
                      capturedEvents.add(
                        WorkflowExecutionEvent(
                          type: event.type,
                          message: '[Step ${i + 1} retry] ${event.message}',
                          createdAt: event.createdAt,
                        ),
                      );
                    },
                  )
                  .timeout(
                    Duration(seconds: _effectiveTimeout(step.timeoutSeconds)),
                  );

              previousResult = retryResponse.finalMessage;
              runtimeVars['step_${step.id}_result'] = previousResult;

              if (!retryResponse.success) {
                chainFailed = true;
                stepResults.last = StepResult(
                  stepId: step.id,
                  status: 'failed',
                  result: previousResult,
                  durationMs: stepStopwatch.elapsedMilliseconds,
                );
              } else {
                stepResults.last = StepResult(
                  stepId: step.id,
                  status: 'success',
                  result: previousResult,
                  durationMs: stepStopwatch.elapsedMilliseconds,
                );
              }
              break;
          }
          if (chainFailed) break;
        }
      } on TimeoutException {
        stepStopwatch.stop();
        stepResults.add(
          StepResult(
            stepId: step.id,
            status: 'failed',
            result: 'Timeout (${_effectiveTimeout(step.timeoutSeconds)}s)',
            durationMs: stepStopwatch.elapsedMilliseconds,
          ),
        );
        if (step.onFailure == StepFailureAction.stop) {
          chainFailed = true;
          break;
        }
      } catch (e) {
        stepStopwatch.stop();
        stepResults.add(
          StepResult(
            stepId: step.id,
            status: 'failed',
            result: 'Error: $e',
            durationMs: stepStopwatch.elapsedMilliseconds,
          ),
        );
        if (step.onFailure == StepFailureAction.stop) {
          chainFailed = true;
          break;
        }
      }
    }

    stopwatch.stop();

    final overallStatus = chainFailed
        ? 'failed'
        : stepResults.every(
            (s) => s.status == 'success' || s.status == 'skipped',
          )
        ? 'success'
        : 'partial';

    final summaryResult = stepResults
        .map(
          (s) =>
              '[${s.stepId}] ${s.status}: ${s.result.length > 80 ? '${s.result.substring(0, 80)}...' : s.result}',
        )
        .join('\n');

    await _repo.updateLastRun(
      wf.id,
      lastRun: DateTime.now(),
      lastResult: summaryResult,
      retryCount: 0,
    );

    await _repo.logExecution(
      WorkflowExecution(
        workflowId: wf.id,
        agentId: wf.agentId,
        workflowTitle: wf.title,
        status: overallStatus,
        result: summaryResult,
        executedAt: DateTime.now(),
        durationMs: stopwatch.elapsedMilliseconds,
        events: List.unmodifiable(capturedEvents),
        stepResults: List.unmodifiable(stepResults),
      ),
    );

    if (wf.notification.showResult) {
      await WorkflowNotificationService.cancel(notifId);
      await WorkflowNotificationService.show(
        id: notifId,
        title: overallStatus == 'success'
            ? '✅ ${wf.title} (${stepResults.length} steps)'
            : '❌ ${wf.title} — $overallStatus',
        body: previousResult.isNotEmpty ? previousResult : summaryResult,
        style: wf.notification.style.name,
        payload: 'workflow:${wf.id}',
      );
    }

    if (wf.sendToChat) {
      final emoji = overallStatus == 'success' ? '✅' : '❌';
      await _injectToChat(
        wf.agentId,
        '$emoji Workflow **${wf.title}** ($overallStatus) — ${stepResults.length} steps completed.',
      );
    }
  }

  /// Wrap a chained step's user instruction in a structured workflow context.
  ///
  /// Domain-agnostic: works for summarize → send-to-chat, fetch → save-note,
  /// list-events → write-file, etc. The contract enforced by this block:
  ///
  ///   1. The previous step output is INLINE below — already retrieved.
  ///   2. The agent MUST act on it directly. No re-fetching, no re-reading.
  ///   3. If the user asks to "send / share / save / write / forward" it,
  ///      the runtime should pick a delivery tool (chat, notes, files, etc.)
  ///      and pass the inline content as the body — not a tool that fetches
  ///      data again.
  ///   4. Concrete facts in the previous output must be preserved verbatim;
  ///      no inventing names, numbers, or items.
  /// Build the userMessage for a chained step (i ≥ 1).
  ///
  /// Keeps the actual instruction front-and-center so the analyzer's intent
  /// classification keys on the verbs/objects the user wrote (e.g. "kirim ke
  /// chat", "simpan ke notes", "bikin file"). The previous step output is
  /// delivered separately as a recentMessages turn — NOT inlined here — so
  /// it doesn't drown out the instruction's keywords.
  String _buildChainedUserMessage({
    required int stepIndex,
    required int totalSteps,
    required String userInstruction,
  }) {
    final buf = StringBuffer()
      ..writeln('[CHAINED WORKFLOW STEP ${stepIndex + 1} of $totalSteps]')
      ..writeln(
        'The previous step\'s output is in the conversation above (most '
        'recent assistant turn). Treat it as data already retrieved — do '
        'NOT call any tool to fetch, read, list, or summarize the same '
        'kind of data again.',
      )
      ..writeln(
        'If this step asks to send / share / save / write / forward / post / '
        'deliver the data, choose a delivery tool that takes a content body '
        '(chat.send, notes.create, files.write, intent.open_url, etc.). '
        'Decide the body from the instruction: if it asks to relay / forward '
        'the data as-is, use the previous turn\'s content verbatim; if it '
        'asks you to respond / react / reply / comment on / rephrase the '
        'data, WRITE YOUR OWN new text that builds on it (do not just resend '
        'the same content). Either way, stay grounded in the real facts '
        '(items, names, numbers, dates) — never invent details that are not '
        'in the previous output.',
      )
      ..writeln('')
      ..writeln('Instruction for this step:')
      ..write(userInstruction);
    return buf.toString();
  }

  /// Synthetic user turn placed BEFORE the assistant turn that holds the
  /// previous step output. Gives the conversation history a coherent shape
  /// (user asked → assistant produced output) so the planner sees natural
  /// turn-taking instead of an orphaned assistant turn.
  String _previousStepInstructionMarker(int stepIndex) {
    return '[Previous workflow step $stepIndex output below — already '
        'produced for this chain. Use it as authoritative data for the '
        'next step instead of fetching again.]';
  }

  /// Trigger-var keys that, when referenced in a user's prompt, should be
  /// masked with a reference marker rather than substituted with the live
  /// content. Their content lives once in the `[TRIGGER CONTEXT]` block.
  static const _maskedTriggerKeys = {
    'notif',
    'notif_app',
    'notif_title',
    'notif_body',
    'notif_keyword',
    'app_name',
    'app_package',
    'battery_level',
    'battery_state',
  };

  /// For each masked trigger key referenced by [prompt], return a map that
  /// overrides the value in [vars] with a short reference marker. Used to
  /// prevent the analyzer from seeing the same content keywords twice (once
  /// inline, once in `[TRIGGER CONTEXT]`).
  ///
  /// When [onlyKeysReferenced] is true, the returned map only contains
  /// overrides for keys the prompt actually mentions. Otherwise it returns
  /// a full copy of [vars] with the masks applied (for callers that pass
  /// the result directly to `substitute`).
  Map<String, String> _maskTriggerVarReferences({
    required String prompt,
    required Map<String, String> vars,
    required Map<String, String> triggerVars,
    bool onlyKeysReferenced = false,
  }) {
    final out = onlyKeysReferenced
        ? <String, String>{}
        : Map<String, String>.from(vars);
    if (triggerVars.isEmpty) return out;

    for (final key in _maskedTriggerKeys) {
      final value = triggerVars[key];
      if (value == null || value.isEmpty) continue;
      final referenced =
          RegExp('(?<![\\w@])@$key\\b').hasMatch(prompt) ||
          prompt.contains('{{$key}}');
      if (!referenced) continue;
      out[key] = '<see TRIGGER CONTEXT block below for the live $key value>';
    }
    return out;
  }

  /// Prepend a `[TRIGGER CONTEXT]` block describing the notification that
  /// fired this workflow. Tells the agent the data is inline so it doesn't
  /// go hunting for tools to fetch chat / notification history.
  ///
  /// No-op when there's no notification trigger context.
  String _wrapWithTriggerContext(
    String prompt,
    Map<String, String> triggerVars,
  ) {
    final notif = triggerVars['notif'] ?? '';
    if (notif.isEmpty) return prompt;
    final app = triggerVars['notif_app'] ?? '';
    final keyword = triggerVars['notif_keyword'] ?? '';
    final title = triggerVars['notif_title'] ?? '';
    final body = triggerVars['notif_body'] ?? '';

    final buf = StringBuffer()
      ..writeln('[TRIGGER CONTEXT]')
      ..writeln(
        'This workflow run was fired by ONE specific incoming Android '
        'notification — the single one that matched your trigger keyword. '
        'That notification is delivered to you INLINE below and is the '
        'COMPLETE and ONLY input for this step. You already have it; you do '
        'NOT need any tool to read, fetch, or look it up.',
      )
      ..writeln(
        'CRITICAL: Do NOT call notification.read_recent, '
        'notification.summarize, notification.classify, or any other tool '
        'that reads the notification tray. Those return DIFFERENT, unrelated '
        'notifications and will produce the wrong result (a general digest of '
        'everything instead of this one item). Work ONLY from the single '
        'inline notification below.',
      )
      ..writeln(
        'Treat the inline notification text as the authoritative source. '
        'When summarizing / extracting, work directly from this text and '
        'preserve only facts that are actually present in it. Do NOT invent '
        'items, names, numbers, or details that are not in the notification, '
        'and do NOT ask the user to forward / paste the content again.',
      );
    if (app.isNotEmpty) buf.writeln('- App: $app');
    if (keyword.isNotEmpty) buf.writeln('- Matched keyword: $keyword');
    if (title.isNotEmpty) buf.writeln('- Title: $title');
    if (body.isNotEmpty) buf.writeln('- Body: $body');
    buf
      ..writeln('[/TRIGGER CONTEXT]')
      ..writeln()
      ..writeln('[USER PROMPT]')
      ..write(prompt);
    return buf.toString();
  }

  /// Simple condition evaluator for step conditions.
  /// Supports: "prev.contains('keyword')", "prev.isEmpty", "prev.isNotEmpty"
  bool _evaluateCondition(
    String condition,
    String previousResult,
    Map<String, String> vars,
  ) {
    final trimmed = condition.trim();

    // prev.contains('...')
    final containsMatch = RegExp(
      r"prev\.contains\('(.+?)'\)",
    ).firstMatch(trimmed);
    if (containsMatch != null) {
      return previousResult.contains(containsMatch.group(1)!);
    }

    // prev.isEmpty
    if (trimmed == 'prev.isEmpty') return previousResult.isEmpty;

    // prev.isNotEmpty
    if (trimmed == 'prev.isNotEmpty') return previousResult.isNotEmpty;

    // prev.length > N
    final lengthMatch = RegExp(
      r'prev\.length\s*([><=!]+)\s*(\d+)',
    ).firstMatch(trimmed);
    if (lengthMatch != null) {
      final op = lengthMatch.group(1)!;
      final n = int.parse(lengthMatch.group(2)!);
      switch (op) {
        case '>':
          return previousResult.length > n;
        case '<':
          return previousResult.length < n;
        case '>=':
          return previousResult.length >= n;
        case '<=':
          return previousResult.length <= n;
        case '==':
          return previousResult.length == n;
        case '!=':
          return previousResult.length != n;
      }
    }

    // Variable check: varName == 'value'
    final varMatch = RegExp(r"(\w+)\s*==\s*'(.+?)'").firstMatch(trimmed);
    if (varMatch != null) {
      final varName = varMatch.group(1)!;
      final expected = varMatch.group(2)!;
      return (vars[varName] ?? previousResult) == expected;
    }

    // Default: condition is truthy if non-empty.
    return true;
  }

  Future<void> _handleFailure(
    WorkflowModel wf,
    String error,
    int durationMs,
    List<WorkflowExecutionEvent> events,
  ) async {
    await _repo.updateLastRun(
      wf.id,
      lastRun: DateTime.now(),
      lastResult: 'FAILED: $error',
      retryCount: wf.retryCount + 1,
    );

    await _repo.logExecution(
      WorkflowExecution(
        workflowId: wf.id,
        agentId: wf.agentId,
        workflowTitle: wf.title,
        status: 'failed',
        result: error,
        executedAt: DateTime.now(),
        durationMs: durationMs,
        events: List.unmodifiable(events),
      ),
    );

    final notifId = wf.id.hashCode.abs() % 2147483647;
    await WorkflowNotificationService.cancel(notifId);
    await WorkflowNotificationService.show(
      id: notifId,
      title: '❌ ${wf.title}',
      body: error,
      style: wf.notification.style.name,
      payload: 'workflow:${wf.id}',
    );

    if (wf.sendToChat) {
      await _injectToChat(
        wf.agentId,
        '❌ Workflow **${wf.title}** gagal: $error',
      );
    }
  }

  /// Inject a message into the agent's chat history.
  Future<void> _injectToChat(String agentId, String message) async {
    try {
      final chatService = ChatHistoryService();
      await chatService.addMessage(
        agentId,
        ChatMessage(role: 'assistant', content: message),
      );
      // Bump unread badge unless the user is currently viewing that chat.
      await UnreadService.instance.increment(agentId);
    } catch (_) {
      // Best-effort.
    }
  }
}

/// Provider for the workflow runner.
final workflowRunnerProvider = Provider<WorkflowRunner>((ref) {
  return WorkflowRunner(ref);
});

/// Pairs a queued workflow with the trigger context that fired it.
/// Trigger context is empty for scheduled/interval workflows and populated
/// for event-driven workflows (notification keyword, app opened, etc.).
class _QueuedWorkflow {
  const _QueuedWorkflow(this.workflow, this.triggerVars);

  final WorkflowModel workflow;
  final Map<String, String> triggerVars;
}
