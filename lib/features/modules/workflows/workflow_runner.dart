import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/agent_runtime/runtime_engine.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import '../../agents/data/agent_repository.dart';
import '../../chat/data/chat_history_service.dart';
import '../../chat/data/unread_service.dart';
import '../../providers/data/provider_repository.dart';
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

  /// Priority-ordered execution queue.
  final Queue<WorkflowModel> _executionQueue = Queue();
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

      _enqueue(wf.copyWith(lastRun: now));
    }
  }

  /// Enqueue a workflow for execution (used by both scheduler and event listener).
  void enqueue(WorkflowModel wf) => _enqueue(wf);

  void _enqueue(WorkflowModel wf) {
    // Insert into queue based on priority.
    if (_executionQueue.isEmpty ||
        wf.priority.index <= _executionQueue.first.priority.index) {
      _executionQueue.addFirst(wf);
    } else {
      _executionQueue.addLast(wf);
    }
    _processQueue();
  }

  /// Process the execution queue sequentially.
  Future<void> _processQueue() async {
    if (_processingQueue) return;
    _processingQueue = true;

    try {
      while (_executionQueue.isNotEmpty) {
        final wf = _executionQueue.removeFirst();
        if (_runningWorkflows.contains(wf.id)) continue;

        _runningWorkflows.add(wf.id);
        await WorkflowForegroundService.start(workflowTitle: wf.title);
        try {
          await _executeWorkflow(wf);
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
      final alreadyClaimedThisOccurrence = lr.year == triggerToday.year &&
          lr.month == triggerToday.month &&
          lr.day == triggerToday.day &&
          !lr.isBefore(triggerToday) &&
          lr.difference(triggerToday).inMinutes < 10;
      if (alreadyClaimedThisOccurrence) return false;
    }

    return true;
  }

  /// Execute a workflow — handles both single-step and chained modes.
  Future<void> _executeWorkflow(WorkflowModel wf) async {
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
        await _handleFailure(wf, 'Agent tidak ditemukan: ${wf.agentId}', 0, capturedEvents);
        return;
      }
      final provider = providers.where((p) => p.id == agent.providerId).firstOrNull;
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
        await _executeChained(wf, engine, provider, agent, capturedEvents, stopwatch, notifId);
      } else {
        // ─── Single-Step Execution ──────────────────────────────────────────
        await _executeSingle(wf, engine, provider, agent, capturedEvents, stopwatch, notifId);
      }
    } on TimeoutException {
      stopwatch.stop();
      await _handleFailure(wf, 'Timeout: eksekusi melebihi ${_effectiveTimeout(wf.timeoutSeconds)} detik.', stopwatch.elapsedMilliseconds, capturedEvents);
    } catch (e, st) {
      stopwatch.stop();
      // ignore: avoid_print
      print('[WorkflowRunner] ${wf.title} error: $e\n$st');
      await _handleFailure(wf, 'Error: $e', stopwatch.elapsedMilliseconds, capturedEvents);
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
  ) async {
    final now = DateTime.now();
    final vars = Map<String, String>.from(wf.variables);
    vars['date'] = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final prompt = _resolveVariables(wf.prompt, vars, {});

    final response = await engine.run(
      AgentRuntimeRequest(
        agentId: wf.agentId,
        agentName: agent.name,
        userMessage: prompt,
        source: RequestSource.workflow,
      ),
      provider: provider,
      autoApproveSensitive: wf.allowSensitive,
      onEvent: (event) {
        capturedEvents.add(WorkflowExecutionEvent(
          type: event.type,
          message: event.message,
          createdAt: event.createdAt,
        ));
      },
    ).timeout(Duration(seconds: _effectiveTimeout(wf.timeoutSeconds)));

    stopwatch.stop();
    final result = response.finalMessage;

    await _repo.updateLastRun(wf.id, lastRun: DateTime.now(), lastResult: result, retryCount: 0);

    await _repo.logExecution(WorkflowExecution(
      workflowId: wf.id,
      agentId: wf.agentId,
      workflowTitle: wf.title,
      status: response.success ? 'success' : 'failed',
      result: result,
      executedAt: DateTime.now(),
      durationMs: stopwatch.elapsedMilliseconds,
      events: List.unmodifiable(capturedEvents),
    ));

    if (wf.notification.showResult) {
      await WorkflowNotificationService.cancel(notifId);
      await WorkflowNotificationService.show(
        id: notifId,
        title: response.success
            ? '✅ ${wf.title}'
            : '❌ ${wf.title}',
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
    dynamic provider,
    dynamic agent,
    List<WorkflowExecutionEvent> capturedEvents,
    Stopwatch stopwatch,
    int notifId,
  ) async {
    final stepResults = <StepResult>[];
    String previousResult = '';
    bool chainFailed = false;

    // Runtime variables: start with workflow defaults, accumulate step results.
    final runtimeVars = Map<String, String>.from(wf.variables);
    final now = DateTime.now();
    runtimeVars['date'] = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    for (int i = 0; i < wf.steps.length; i++) {
      final step = wf.steps[i];

      // Evaluate condition.
      if (step.condition != null && step.condition!.isNotEmpty) {
        if (!_evaluateCondition(step.condition!, previousResult, runtimeVars)) {
          stepResults.add(StepResult(
            stepId: step.id,
            status: 'skipped',
            result: 'Condition not met: ${step.condition}',
          ));
          capturedEvents.add(WorkflowExecutionEvent(
            type: 'step_skipped',
            message: 'Step ${i + 1} "${step.id}" skipped: condition not met.',
            createdAt: DateTime.now(),
          ));
          continue;
        }
      }

      // Resolve variables in prompt.
      runtimeVars['prev'] = previousResult;
      runtimeVars['step_index'] = i.toString();
      final rawPrompt = _resolveVariables(step.prompt, runtimeVars, {});

      // Inject system context so the agent understands what {{prev}} was.
      // This prevents the agent from saying "berikan ide jurnalnya" when
      // {{prev}} already contains the journal content from step 1.
      final systemPrefix = i > 0 && previousResult.isNotEmpty
          ? '[SYSTEM CONTEXT: This is step ${i + 1} of a multi-step workflow. '
            'The previous step\'s output is provided below as context — use it '
            'directly, do NOT ask the user to provide it again.]\n'
            '--- PREVIOUS STEP RESULT ---\n$previousResult\n'
            '--- END PREVIOUS STEP RESULT ---\n\n'
          : '';
      final resolvedPrompt = '$systemPrefix$rawPrompt';

      capturedEvents.add(WorkflowExecutionEvent(
        type: 'step_start',
        message: 'Starting step ${i + 1}: ${step.id}',
        createdAt: DateTime.now(),
      ));

      final stepStopwatch = Stopwatch()..start();

      try {
        final response = await engine.run(
          AgentRuntimeRequest(
            agentId: wf.agentId,
            agentName: agent.name,
            userMessage: resolvedPrompt,
            source: RequestSource.workflow,
          ),
          provider: provider,
          autoApproveSensitive: wf.allowSensitive,
          onEvent: (event) {
            capturedEvents.add(WorkflowExecutionEvent(
              type: event.type,
              message: '[Step ${i + 1}] ${event.message}',
              createdAt: event.createdAt,
            ));
          },
        ).timeout(Duration(seconds: _effectiveTimeout(step.timeoutSeconds)));

        stepStopwatch.stop();
        previousResult = response.finalMessage;
        runtimeVars['step_${step.id}_result'] = previousResult;

        stepResults.add(StepResult(
          stepId: step.id,
          status: response.success ? 'success' : 'failed',
          result: previousResult,
          durationMs: stepStopwatch.elapsedMilliseconds,
        ));

        if (!response.success) {
          switch (step.onFailure) {
            case StepFailureAction.stop:
              chainFailed = true;
              capturedEvents.add(WorkflowExecutionEvent(
                type: 'chain_stopped',
                message: 'Chain stopped at step ${i + 1} due to failure.',
                createdAt: DateTime.now(),
              ));
              break;
            case StepFailureAction.skip:
              capturedEvents.add(WorkflowExecutionEvent(
                type: 'step_failure_skipped',
                message: 'Step ${i + 1} failed but continuing (skip policy).',
                createdAt: DateTime.now(),
              ));
              break;
            case StepFailureAction.retry:
              // Retry once.
              capturedEvents.add(WorkflowExecutionEvent(
                type: 'step_retry',
                message: 'Retrying step ${i + 1}...',
                createdAt: DateTime.now(),
              ));
              final retryResponse = await engine.run(
                AgentRuntimeRequest(
                  agentId: wf.agentId,
                  agentName: agent.name,
                  userMessage: resolvedPrompt,
                  source: RequestSource.workflow,
                ),
                provider: provider,
                autoApproveSensitive: wf.allowSensitive,
                onEvent: (event) {
                  capturedEvents.add(WorkflowExecutionEvent(
                    type: event.type,
                    message: '[Step ${i + 1} retry] ${event.message}',
                    createdAt: event.createdAt,
                  ));
                },
              ).timeout(Duration(seconds: _effectiveTimeout(step.timeoutSeconds)));

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
        stepResults.add(StepResult(
          stepId: step.id,
          status: 'failed',
          result: 'Timeout (${_effectiveTimeout(step.timeoutSeconds)}s)',
          durationMs: stepStopwatch.elapsedMilliseconds,
        ));
        if (step.onFailure == StepFailureAction.stop) {
          chainFailed = true;
          break;
        }
      } catch (e) {
        stepStopwatch.stop();
        stepResults.add(StepResult(
          stepId: step.id,
          status: 'failed',
          result: 'Error: $e',
          durationMs: stepStopwatch.elapsedMilliseconds,
        ));
        if (step.onFailure == StepFailureAction.stop) {
          chainFailed = true;
          break;
        }
      }
    }

    stopwatch.stop();

    final overallStatus = chainFailed
        ? 'failed'
        : stepResults.every((s) => s.status == 'success' || s.status == 'skipped')
            ? 'success'
            : 'partial';

    final summaryResult = stepResults
        .map((s) => '[${s.stepId}] ${s.status}: ${s.result.length > 80 ? '${s.result.substring(0, 80)}...' : s.result}')
        .join('\n');

    await _repo.updateLastRun(wf.id, lastRun: DateTime.now(), lastResult: summaryResult, retryCount: 0);

    await _repo.logExecution(WorkflowExecution(
      workflowId: wf.id,
      agentId: wf.agentId,
      workflowTitle: wf.title,
      status: overallStatus,
      result: summaryResult,
      executedAt: DateTime.now(),
      durationMs: stopwatch.elapsedMilliseconds,
      events: List.unmodifiable(capturedEvents),
      stepResults: List.unmodifiable(stepResults),
    ));

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

  /// Resolve {{variable}} placeholders in a prompt string.
  String _resolveVariables(
    String prompt,
    Map<String, String> variables,
    Map<String, String> runtimeContext,
  ) {
    var resolved = prompt;
    final allVars = {...variables, ...runtimeContext};
    for (final entry in allVars.entries) {
      resolved = resolved.replaceAll('{{${entry.key}}}', entry.value);
    }
    return resolved;
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
    final containsMatch = RegExp(r"prev\.contains\('(.+?)'\)").firstMatch(trimmed);
    if (containsMatch != null) {
      return previousResult.contains(containsMatch.group(1)!);
    }

    // prev.isEmpty
    if (trimmed == 'prev.isEmpty') return previousResult.isEmpty;

    // prev.isNotEmpty
    if (trimmed == 'prev.isNotEmpty') return previousResult.isNotEmpty;

    // prev.length > N
    final lengthMatch = RegExp(r'prev\.length\s*([><=!]+)\s*(\d+)').firstMatch(trimmed);
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

    await _repo.logExecution(WorkflowExecution(
      workflowId: wf.id,
      agentId: wf.agentId,
      workflowTitle: wf.title,
      status: 'failed',
      result: error,
      executedAt: DateTime.now(),
      durationMs: durationMs,
      events: List.unmodifiable(events),
    ));

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
      await _injectToChat(wf.agentId, '❌ Workflow **${wf.title}** gagal: $error');
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
