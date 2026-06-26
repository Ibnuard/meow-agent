import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/agent_soul_repository.dart';
import '../../../services/agent_runtime/runtime_engine.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import '../../agents/data/agent_repository.dart';
import '../../chat/data/chat_history_service.dart';
import '../../chat/data/chat_messages_notifier.dart';
import '../../chat/data/unread_service.dart';
import '../notification_intelligence/notification_models.dart';
import '../notification_intelligence/notification_repository.dart';
import '../../providers/data/provider_repository.dart';
import 'workflow_builtin_vars.dart';
import 'workflow_foreground_service.dart';
import 'workflow_model.dart';
import 'workflow_notification_service.dart';
import 'workflow_run_ledger.dart';
import 'workflow_scheduler.dart';
import 'workflow_repository.dart';
import '../../settings/data/notification_sound_provider.dart';
import '../../../services/agent_runtime/prompt_constants.dart';
import '../../settings/data/app_language_provider.dart';

/// Runs in the main isolate. Uses dynamic scheduling to check for due workflows
/// and executes them via RuntimeEngine with priority queue ordering.
class WorkflowRunner {
  WorkflowRunner(this._ref);

  final Ref _ref;
  final WorkflowRepository _repo = WorkflowRepository();

  /// Persistent store for live workflow-run state (GitHub-Actions style
  /// "currently running" view). One ledger per run, spanning all steps/agents.
  final WorkflowRunDatabase _runDb = WorkflowRunDatabase();
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

  AppStrings get _s {
    final langPref = _ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }

  /// Priority-ordered execution queue. Each entry pairs a workflow with the
  /// optional trigger context that fired it (e.g. notification metadata).
  final Queue<_QueuedWorkflow> _executionQueue = Queue();
  bool _processingQueue = false;

  /// Start the dynamic scheduler.
  void start() {
    _timer?.cancel();
    _scheduleNextCheck();
    // Also run immediately on start.
    checkAndRun();
  }

  /// Stop the runner.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _executionQueue.clear();
  }

  /// Await execution queue drain and workflow completion.
  Future<void> waitUntilIdle() async {
    while (_processingQueue ||
        _runningWorkflows.isNotEmpty ||
        _executionQueue.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
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
      checkAndRun();
      _scheduleNextCheck();
    });
  }

  /// Check all enabled workflows and enqueue any that are due.
  Future<void> checkAndRun() async {
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
      final lastTime = wf.lastRun ?? wf.createdAt;
      final elapsed = now.difference(lastTime).inSeconds;
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
          _s.workflowAgentNotFound(wf.agentId),
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
          _s.workflowProviderNotFound(agent.providerId, agent.name),
          0,
          capturedEvents,
        );
        return;
      }
      final runtimeTriggerVars =
          await _triggerVarsWithScheduledNotificationContext(wf, triggerVars);

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
          runtimeTriggerVars,
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
          runtimeTriggerVars,
        );
      }
    } on TimeoutException {
      stopwatch.stop();
      await _handleFailure(
        wf,
        _s.workflowTimeoutSeconds(_effectiveTimeout(wf.timeoutSeconds)),
        stopwatch.elapsedMilliseconds,
        capturedEvents,
      );
    } catch (e, st) {
      stopwatch.stop();
      // ignore: avoid_print
      print('[WorkflowRunner] ${wf.title} error: $e\n$st');
      await _handleFailure(
        wf,
        '${_s.workflowErrorGeneric}: $e',
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
      soulRepo: _ref.read(agentSoulRepositoryProvider),
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
    final apiResolved = await WorkflowBuiltInVars.resolveApiReferences(
      resolvedPrompt,
    );
    final prompt = _wrapWithTriggerContext(apiResolved, triggerVars);

    // When triggered by a notification, exclude reading tools (data is inline)
    // and pass the reply key so the engine can make notification.reply available.
    final notifKey = triggerVars['notif_key'] ?? '';
    final metadata = <String, dynamic>{};
    if (notifKey.isNotEmpty) {
      metadata['exclude_tools'] = [
        'notification.read_recent',
        'notification.summarize',
        'notification.classify',
      ];
      metadata['notif_reply_key'] = notifKey;
    }
    // Track run in the ledger so it appears in Activity while running.
    final run = WorkflowRunLedger.start(
      workflowId: wf.id,
      workflowTitle: wf.title,
      agentId: wf.agentId,
      steps: [
        WorkflowStepEntry(
          index: 0,
          stepId: 'single_0',
          agentId: wf.agentId,
          agentName: agent.name,
          mainGoal: wf.prompt.length > 240
              ? '${wf.prompt.substring(0, 240)}…'
              : wf.prompt,
          status: WorkflowStepStatus.running,
        ),
      ],
    );
    await _persistRun(run);

    final response = await engine
        .run(
          AgentRuntimeRequest(
            agentId: wf.agentId,
            agentName: agent.name,
            userMessage: prompt,
            source: RequestSource.workflow,
            metadata: metadata,
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

    // Mark run as complete in the ledger.
    final stepEntry = run.steps.first;
    stepEntry.status = response.success
        ? WorkflowStepStatus.success
        : WorkflowStepStatus.failed;
    stepEntry.result = response.finalMessage;
    stepEntry.durationMs = stopwatch.elapsedMilliseconds;
    run.status = response.success
        ? WorkflowRunStatus.success
        : WorkflowRunStatus.failed;
    run.finishedAt = DateTime.now();
    await _persistRun(run);

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
        soundFileName: _ref.read(notificationSoundProvider).fileName,
      );
    }

    if (wf.sendToChat) {
      await _injectToChat(
        wf.agentId,
        response.success
            ? _s.workflowSingleSuccess(wf.title)
            : _s.workflowSingleFailed(wf.title),
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

    // Output of each completed step, keyed by 1-based step number. Powers the
    // dynamic `@step1 .. @stepN` variables so a later step can reference ANY
    // earlier step's output, not just the immediately previous one (`@prev`).
    final stepOutputs = <int, String>{};

    // Built-in variables that don't depend on the running agent are computed
    // once. Per-step we'll re-resolve to refresh `{{chat_session}}` with the
    // step's specific agent and to override `@prev` / `@stepN`.
    final baseBuiltIns = await WorkflowBuiltInVars.resolve(
      agentName: fallbackAgent.name,
      agentId: fallbackAgent.id,
      soulRepo: _ref.read(agentSoulRepositoryProvider),
      now: DateTime.now(),
      triggerVars: triggerVars,
    );

    // ─── Run ledger ────────────────────────────────────────────────────────
    //
    // One ledger spans the WHOLE run across every step/agent. This is the
    // authoritative run state (GitHub-Actions style): steps are main goals,
    // executed strictly one-by-one. It replaces the engine's per-(agent,
    // source) resume ledger for workflows, which collided when two steps
    // shared an agent. Persisted live so a "currently running" view can read
    // it; swept to failed on next app open if the process dies mid-run.
    final runEntries = <WorkflowStepEntry>[
      for (var i = 0; i < wf.steps.length; i++)
        WorkflowStepEntry(
          index: i,
          stepId: wf.steps[i].id,
          agentId: wf.steps[i].agentId ?? fallbackAgent.id,
          agentName:
              (wf.steps[i].agentId == null
                      ? fallbackAgent
                      : agents
                            .where((a) => a.id == wf.steps[i].agentId)
                            .firstOrNull)
                  ?.name
                  ?.toString() ??
              fallbackAgent.name.toString(),
          mainGoal: wf.steps[i].prompt.length > 240
              ? '${wf.steps[i].prompt.substring(0, 240)}…'
              : wf.steps[i].prompt,
        ),
    ];
    final run = WorkflowRunLedger.start(
      workflowId: wf.id,
      workflowTitle: wf.title,
      agentId: wf.agentId,
      steps: runEntries,
    );
    await _persistRun(run);

    for (int i = 0; i < wf.steps.length; i++) {
      final step = wf.steps[i];
      final stepAgent = step.agentId == null
          ? fallbackAgent
          : agents.where((a) => a.id == step.agentId).firstOrNull;
      final stepProvider = stepAgent == null
          ? null
          : providers.where((p) => p.id == stepAgent.providerId).firstOrNull;

      if (stepAgent == null || stepProvider == null) {
        final reason = stepAgent == null
            ? _s.workflowStepAgentNotFound
            : _s.workflowStepProviderNotFound(stepAgent.name);
        stepResults.add(
          StepResult(stepId: step.id, status: 'failed', result: reason),
        );
        capturedEvents.add(
          WorkflowExecutionEvent(
            type: 'step_failed',
            message:
                'Step ${i + 1} "${step.id}" failed: agent/provider not found.',
            createdAt: DateTime.now(),
          ),
        );
        _markStep(
          run,
          i,
          WorkflowStepStatus.failed,
          result: reason,
          failureReason: reason,
        );
        await _persistRun(run);
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
        ..['prev'] = previousResult;
      // Dynamic @step1..@stepN — the output of each completed step so far.
      stepOutputs.forEach((n, out) => runtimeVars['step$n'] = out);

      // Evaluate condition.
      if (step.condition != null && step.condition!.isNotEmpty) {
        if (!_evaluateCondition(step.condition!, previousResult, runtimeVars)) {
          final reason = 'Condition not met: ${step.condition}';
          stepResults.add(
            StepResult(stepId: step.id, status: 'skipped', result: reason),
          );
          capturedEvents.add(
            WorkflowExecutionEvent(
              type: 'step_skipped',
              message: 'Step ${i + 1} "${step.id}" skipped: condition not met.',
              createdAt: DateTime.now(),
            ),
          );
          _markStep(run, i, WorkflowStepStatus.skipped, result: reason);
          await _persistRun(run);
          continue;
        }
      }

      // Mark the step running so the live view reflects current progress.
      run.currentStepIndex = i;
      _markStep(run, i, WorkflowStepStatus.running);
      await _persistRun(run);

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
            '<the previous step output (step $i) — provided as the most '
            'recent assistant message in the conversation history>';
      }

      // Explicit @stepN references: collect each completed step the prompt
      // points at (1..i; later/self refs are dropped — nothing produced them
      // yet). Mask them the same way as @prev so their content isn't
      // double-injected; they're delivered as labeled conversation turns.
      final referencedSteps = <int>{};
      for (final m in RegExp(
        r'(?<![\w@])@step(\d+)\b',
      ).allMatches(step.prompt)) {
        final n = int.tryParse(m.group(1)!);
        if (n != null && n >= 1 && n <= i) referencedSteps.add(n);
      }
      for (final n in referencedSteps) {
        if (n == i) {
          // Step number i == the immediately previous step (== @prev). Point
          // at the prev channel so it isn't delivered twice.
          substituteVars['step$n'] =
              '<the previous step output (step $n) — provided as the most '
              'recent assistant message in the conversation history>';
        } else {
          substituteVars['step$n'] =
              '<the output of step $n — provided in the conversation history, '
              'labeled [Step $n output]>';
        }
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
      rawPrompt = await WorkflowBuiltInVars.resolveApiReferences(rawPrompt);

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

      // Labeled conversation turns for explicitly-referenced EARLIER steps
      // (@stepN where n < i). Delivered as history — same anti-double-
      // injection rule as @prev — so their content never pollutes the
      // instruction's intent keywords. Ordered ascending so the agent reads
      // them step 1 → step k before the most-recent prev turn.
      final earlierTurns = <ChatMessage>[];
      final earlierRefs = referencedSteps.where((n) => n < i).toList()..sort();
      for (final n in earlierRefs) {
        final out = stepOutputs[n];
        if (out == null || out.isEmpty) continue;
        earlierTurns
          ..add(ChatMessage(role: 'user', content: _earlierStepMarker(n)))
          ..add(
            ChatMessage(role: 'assistant', content: '[Step $n output]\n$out'),
          );
        final preview = out.length > 500
            ? '${out.substring(0, 500)}… (${out.length} chars total)'
            : out;
        capturedEvents.add(
          WorkflowExecutionEvent(
            type: 'step_handoff',
            message:
                '[Step ${i + 1}] Received @step$n (${out.length} chars):\n'
                '$preview',
            createdAt: DateTime.now(),
          ),
        );
      }

      if (i == 0) {
        stepUserMessage = rawPrompt;
      } else if (previousResult.isEmpty && earlierTurns.isEmpty) {
        stepUserMessage = rawPrompt;
      } else {
        stepUserMessage = _buildChainedUserMessage(
          stepIndex: i,
          totalSteps: wf.steps.length,
          userInstruction: rawPrompt,
        );
        stepRecentMessages = [
          ...earlierTurns,
          if (previousResult.isNotEmpty) ...[
            ChatMessage(
              role: 'user',
              content: _previousStepInstructionMarker(i),
            ),
            ChatMessage(role: 'assistant', content: previousResult),
          ],
        ];

        // Observability: record the EXACT previous-step output handed to this
        // step as conversation history. Lets the user verify whether step N
        // received correct data vs. hallucinated — without this, a wrong
        // result is indistinguishable from a bad handoff.
        if (previousResult.isNotEmpty) {
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
        // Record this step's output for @stepN references by later steps.
        stepOutputs[i + 1] = previousResult;

        // Sensitive block = destroy the chain. The step needed a
        // sensitive/confirmation action but the workflow's "Allow sensitive
        // actions" toggle is off. This is terminal regardless of onFailure.
        if (response.state == AgentRuntimeState.blockedSensitive) {
          final tool = response.pendingTool ?? _s.workflowSensitiveFallbackTool;
          final reason = _s.workflowSensitiveBlocked(i + 1, tool);
          previousResult = reason;
          stepResults.add(
            StepResult(
              stepId: step.id,
              status: 'failed',
              result: reason,
              durationMs: stepStopwatch.elapsedMilliseconds,
            ),
          );
          capturedEvents.add(
            WorkflowExecutionEvent(
              type: 'chain_stopped',
              message:
                  'Step ${i + 1} blocked: needs sensitive permission ($tool). '
                  'Chain failed.',
              createdAt: DateTime.now(),
            ),
          );
          _markStep(
            run,
            i,
            WorkflowStepStatus.blocked,
            result: reason,
            failureReason: 'needs sensitive permission: $tool',
            durationMs: stepStopwatch.elapsedMilliseconds,
          );
          await _persistRun(run);
          chainFailed = true;
          break;
        }

        stepResults.add(
          StepResult(
            stepId: step.id,
            status: response.success ? 'success' : 'failed',
            result: previousResult,
            durationMs: stepStopwatch.elapsedMilliseconds,
          ),
        );

        if (response.success) {
          _markStep(
            run,
            i,
            WorkflowStepStatus.success,
            result: previousResult,
            durationMs: stepStopwatch.elapsedMilliseconds,
          );
          await _persistRun(run);
        }

        if (!response.success) {
          _markStep(
            run,
            i,
            WorkflowStepStatus.failed,
            result: previousResult,
            failureReason: 'step returned failure',
            durationMs: stepStopwatch.elapsedMilliseconds,
          );
          await _persistRun(run);
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
              // Keep @stepN in sync with the retried output.
              stepOutputs[i + 1] = previousResult;

              if (retryResponse.state == AgentRuntimeState.blockedSensitive) {
                final tool =
                    retryResponse.pendingTool ??
                    _s.workflowSensitiveFallbackTool;
                final reason = _s.workflowSensitiveBlocked(i + 1, tool);
                previousResult = reason;
                chainFailed = true;
                stepResults.last = StepResult(
                  stepId: step.id,
                  status: 'failed',
                  result: reason,
                  durationMs: stepStopwatch.elapsedMilliseconds,
                );
                _markStep(
                  run,
                  i,
                  WorkflowStepStatus.blocked,
                  result: reason,
                  failureReason: 'needs sensitive permission: $tool',
                  durationMs: stepStopwatch.elapsedMilliseconds,
                );
                await _persistRun(run);
              } else if (!retryResponse.success) {
                chainFailed = true;
                stepResults.last = StepResult(
                  stepId: step.id,
                  status: 'failed',
                  result: previousResult,
                  durationMs: stepStopwatch.elapsedMilliseconds,
                );
                _markStep(
                  run,
                  i,
                  WorkflowStepStatus.failed,
                  result: previousResult,
                  failureReason: 'step failed after retry',
                  durationMs: stepStopwatch.elapsedMilliseconds,
                );
                await _persistRun(run);
              } else {
                stepResults.last = StepResult(
                  stepId: step.id,
                  status: 'success',
                  result: previousResult,
                  durationMs: stepStopwatch.elapsedMilliseconds,
                );
                _markStep(
                  run,
                  i,
                  WorkflowStepStatus.success,
                  result: previousResult,
                  durationMs: stepStopwatch.elapsedMilliseconds,
                );
                await _persistRun(run);
              }
              break;
          }
          if (chainFailed) break;
        }
      } on TimeoutException {
        stepStopwatch.stop();
        final reason = 'Timeout (${_effectiveTimeout(step.timeoutSeconds)}s)';
        stepResults.add(
          StepResult(
            stepId: step.id,
            status: 'failed',
            result: reason,
            durationMs: stepStopwatch.elapsedMilliseconds,
          ),
        );
        _markStep(
          run,
          i,
          WorkflowStepStatus.failed,
          result: reason,
          failureReason: 'timeout',
          durationMs: stepStopwatch.elapsedMilliseconds,
        );
        await _persistRun(run);
        if (step.onFailure == StepFailureAction.stop) {
          chainFailed = true;
          break;
        }
      } catch (e) {
        stepStopwatch.stop();
        final reason = 'Error: $e';
        stepResults.add(
          StepResult(
            stepId: step.id,
            status: 'failed',
            result: reason,
            durationMs: stepStopwatch.elapsedMilliseconds,
          ),
        );
        _markStep(
          run,
          i,
          WorkflowStepStatus.failed,
          result: reason,
          failureReason: 'runtime error',
          durationMs: stepStopwatch.elapsedMilliseconds,
        );
        await _persistRun(run);
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

    // Finalize the run ledger to a terminal status so it leaves the live
    // "running" set. Best-effort: a persistence failure must not break the run.
    run.status = switch (overallStatus) {
      'success' => WorkflowRunStatus.success,
      'partial' => WorkflowRunStatus.partial,
      _ => WorkflowRunStatus.failed,
    };
    run.finishedAt = DateTime.now();
    await _persistRun(run);
    await _pruneRuns();

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
            : _s.workflowChainedFailed(wf.title, overallStatus),
        body: previousResult.isNotEmpty ? previousResult : summaryResult,
        style: wf.notification.style.name,
        payload: 'workflow:${wf.id}',
        soundFileName: _ref.read(notificationSoundProvider).fileName,
      );
    }

    if (wf.sendToChat) {
      final emoji = overallStatus == 'success' ? '✅' : '❌';
      await _injectToChat(
        wf.agentId,
        '$emoji ${_s.workflowChainedSuccess(wf.title, stepResults.length)}',
      );
    }
  }

  // ─── Run ledger helpers ───────────────────────────────────────────────────

  /// Update a step entry's status/result in place. No-op if the index is out
  /// of range (defensive — entries are built upfront from wf.steps).
  void _markStep(
    WorkflowRunLedger run,
    int index,
    WorkflowStepStatus status, {
    String? result,
    String? failureReason,
    int? durationMs,
  }) {
    final entry = run.stepAt(index);
    if (entry == null) return;
    entry.status = status;
    if (result != null) {
      entry.result = result.length > 2000
          ? '${result.substring(0, 2000)}…'
          : result;
    }
    if (failureReason != null) entry.failureReason = failureReason;
    if (durationMs != null) entry.durationMs = durationMs;
  }

  /// Persist the run ledger. Best-effort: a DB error must never abort a run.
  Future<void> _persistRun(WorkflowRunLedger run) async {
    try {
      await _runDb.upsert(run);
    } catch (e) {
      // ignore: avoid_print
      print('[WorkflowRunner] run-ledger persist failed: $e');
    }
  }

  /// Trim old terminal runs so the table doesn't grow unbounded.
  Future<void> _pruneRuns() async {
    try {
      await _runDb.prune();
    } catch (_) {
      // Non-fatal.
    }
  }

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
  }) => PromptConstants.workflowChainedUserMessage(
    stepIndex: stepIndex,
    totalSteps: totalSteps,
    userInstruction: userInstruction,
  );

  String _previousStepInstructionMarker(int stepIndex) =>
      PromptConstants.workflowPreviousStepMarker(stepIndex);

  String _earlierStepMarker(int stepNumber) =>
      PromptConstants.workflowEarlierStepMarker(stepNumber);

  /// Notification built-ins that can be resolved either from a live
  /// notification event or from recent notification context for scheduled and
  /// interval workflows.
  static const _notificationContextKeys = {
    'notif',
    'notif_app',
    'notif_title',
    'notif_body',
    'notif_sender',
    'notif_keyword',
  };

  Future<Map<String, String>> _triggerVarsWithScheduledNotificationContext(
    WorkflowModel wf,
    Map<String, String> triggerVars,
  ) async {
    if ((triggerVars['notif'] ?? '').trim().isNotEmpty) return triggerVars;
    final scheduled =
        wf.trigger.type == TriggerType.schedule ||
        wf.trigger.type == TriggerType.interval;
    if (!scheduled || !_workflowReferencesNotificationContext(wf)) {
      return triggerVars;
    }

    final recent = await _ref
        .read(notificationRepositoryProvider)
        .getRecent(limit: 10);
    if (recent.error != null) {
      return {
        ...triggerVars,
        'notif': '[recent notifications unavailable: ${recent.error}]',
        'notif_app': '',
        'notif_title': '',
        'notif_body': '',
        'notif_sender': '',
        'notif_keyword': '',
      };
    }
    return {
      ...triggerVars,
      ..._recentNotificationVars(recent.data ?? const []),
    };
  }

  bool _workflowReferencesNotificationContext(WorkflowModel wf) {
    if (_textReferencesNotificationContext(wf.prompt)) return true;
    for (final step in wf.steps) {
      if (_textReferencesNotificationContext(step.prompt) ||
          _textReferencesNotificationContext(step.condition ?? '')) {
        return true;
      }
    }
    return false;
  }

  bool _textReferencesNotificationContext(String text) {
    if (text.isEmpty) return false;
    for (final key in _notificationContextKeys) {
      if (RegExp('(?<![\\w@])@$key\\b').hasMatch(text) ||
          text.contains('{{$key}}')) {
        return true;
      }
    }
    return false;
  }

  Map<String, String> _recentNotificationVars(List<NotificationInfo> recent) {
    if (recent.isEmpty) {
      return const {
        'notif': '[no recent notifications available]',
        'notif_app': '',
        'notif_title': '',
        'notif_body': '',
        'notif_sender': '',
        'notif_keyword': '',
      };
    }

    String lineFor(NotificationInfo n) {
      final title = (n.title ?? '').trim();
      final body = (n.text ?? '').trim();
      final head = title.isEmpty ? n.appName : '${n.appName} — $title';
      return body.isEmpty ? head : '$head: $body';
    }

    final latest = recent.first;
    final titles = recent
        .map((n) => (n.title ?? '').trim())
        .where((v) => v.isNotEmpty)
        .join('\n');
    final bodies = recent
        .map((n) => (n.text ?? '').trim())
        .where((v) => v.isNotEmpty)
        .join('\n');
    final apps = recent
        .map((n) => n.appName.trim())
        .where((v) => v.isNotEmpty)
        .toSet();
    final latestTitle = (latest.title ?? '').trim();
    final sender = latestTitle.isEmpty
        ? latest.appName
        : '$latestTitle via ${latest.appName}';

    return {
      'notif': recent.map(lineFor).join('\n'),
      'notif_app': apps.join(', '),
      'notif_title': titles,
      'notif_body': bodies,
      'notif_sender': sender,
      'notif_keyword': '',
    };
  }

  /// Trigger-var keys that, when referenced in a user's prompt, should be
  /// masked with a reference marker rather than substituted with the live
  /// content. Their content lives once in the `[TRIGGER CONTEXT]` block.
  static const _maskedTriggerKeys = {
    'notif',
    'notif_app',
    'notif_title',
    'notif_body',
    'notif_sender',
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

  /// Prepend a `[TRIGGER CONTEXT]` block describing notification context.
  /// For notification-event triggers this is the notification that fired the
  /// workflow; for schedule/interval triggers it is recent notification
  /// context explicitly requested through `@notif*` built-ins.
  ///
  /// No-op when there's no notification trigger context.
  String _wrapWithTriggerContext(
    String prompt,
    Map<String, String> triggerVars,
  ) {
    final notif = triggerVars['notif'] ?? '';
    if (notif.isEmpty) return prompt;
    return PromptConstants.workflowTriggerContextWrapper(
      prompt: prompt,
      notif: notif,
      app: triggerVars['notif_app'] ?? '',
      keyword: triggerVars['notif_keyword'] ?? '',
      title: triggerVars['notif_title'] ?? '',
      body: triggerVars['notif_body'] ?? '',
      notifKey: triggerVars['notif_key'] ?? '',
    );
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
      soundFileName: _ref.read(notificationSoundProvider).fileName,
    );

    if (wf.sendToChat) {
      await _injectToChat(wf.agentId, _s.workflowFailedStatus(wf.title, error));
    }
  }

  /// Inject a message into the agent's chat history.
  ///
  /// Uses the Riverpod-managed ChatHistoryService so the message persists,
  /// then notifies the ChatMessagesNotifier so the UI updates reactively
  /// even if the user is currently viewing that chat screen.
  Future<void> _injectToChat(String agentId, String message) async {
    try {
      final chatService = _ref.read(chatHistoryServiceProvider);
      final id = await chatService.addMessage(
        agentId,
        ChatMessage(role: 'assistant', content: message),
      );
      // Notify the in-memory notifier so open chat screens see the message.
      try {
        _ref
            .read(chatMessagesProvider(agentId).notifier)
            .addMessage(
              ChatMessage(id: id, role: 'assistant', content: message),
            );
      } catch (_) {
        // Notifier may not exist if no one is watching this agent's chat.
      }
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
