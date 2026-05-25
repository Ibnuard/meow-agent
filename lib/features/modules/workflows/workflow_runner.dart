import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/agent_runtime/runtime_engine.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import '../../agents/data/agent_repository.dart';
import '../../chat/data/chat_history_service.dart';
import '../../providers/data/provider_repository.dart';
import 'workflow_model.dart';
import 'workflow_notification_service.dart';
import 'workflow_repository.dart';

/// Runs in the main isolate. Periodically checks for due workflows
/// and executes them via RuntimeEngine.
class WorkflowRunner {
  WorkflowRunner(this._ref);

  final Ref _ref;
  final WorkflowRepository _repo = WorkflowRepository();
  Timer? _timer;
  final Set<String> _runningWorkflows = {};

  /// Start the periodic check (every 30 seconds).
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _checkAndRun());
    // Also run immediately on start.
    _checkAndRun();
  }

  /// Stop the runner.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Check all enabled workflows and execute any that are due.
  Future<void> _checkAndRun() async {
    final workflows = await _repo.listEnabled();
    final now = DateTime.now();

    // ignore: avoid_print
    print('[WorkflowRunner] Checking ${workflows.length} enabled workflows at $now');

    for (final wf in workflows) {
      if (_runningWorkflows.contains(wf.id)) continue;
      final due = _isDue(wf, now);
      // ignore: avoid_print
      print('[WorkflowRunner] ${wf.title}: due=$due, lastRun=${wf.lastRun}');
      if (!due) continue;

      _runningWorkflows.add(wf.id);
      try {
        // ignore: avoid_print
        print('[WorkflowRunner] Executing ${wf.title}...');
        await _executeWorkflow(wf);
      } finally {
        _runningWorkflows.remove(wf.id);
      }
    }
  }

  /// Check if a workflow is due to run now.
  bool _isDue(WorkflowModel wf, DateTime now) {
    if (wf.trigger.type == TriggerType.interval) {
      // For interval: check if enough time has passed since last run.
      if (wf.lastRun == null) return true;
      final elapsed = now.difference(wf.lastRun!).inMinutes;
      return elapsed >= (wf.trigger.intervalMinutes ?? 60);
    }

    // Schedule: check if current time matches trigger time (within 1 min).
    final hour = wf.trigger.hour ?? 0;
    final minute = wf.trigger.minute ?? 0;

    if (now.hour != hour) return false;
    if ((now.minute - minute).abs() > 1) return false;

    // Check day of week.
    if (wf.trigger.daysOfWeek != null && wf.trigger.daysOfWeek!.isNotEmpty) {
      if (!wf.trigger.daysOfWeek!.contains(now.weekday)) return false;
    }

    // Prevent double-run: check if already ran within last 2 minutes.
    if (wf.lastRun != null) {
      final sinceLastRun = now.difference(wf.lastRun!).inMinutes;
      if (sinceLastRun < 2) return false;
    }

    return true;
  }

  /// Execute a workflow's prompt via RuntimeEngine.
  Future<void> _executeWorkflow(WorkflowModel wf) async {
    final stopwatch = Stopwatch()..start();

    try {
      final engine = _ref.read(agentRuntimeEngineProvider);

      // Resolve provider config for the agent.
      final agents = _ref.read(agentListProvider);
      final providerRepo = _ref.read(providerRepositoryProvider);
      final providers = await providerRepo.loadAll();

      final agent = agents.where((a) => a.id == wf.agentId).firstOrNull;
      if (agent == null) {
        await _handleFailure(
          wf,
          'Agent tidak ditemukan: ${wf.agentId}',
          0,
        );
        return;
      }
      final provider = providers.where((p) => p.id == agent.providerId).firstOrNull;
      if (provider == null) {
        await _handleFailure(
          wf,
          'Provider LLM "${agent.providerId}" tidak ditemukan untuk agent "${agent.name}". Periksa pengaturan provider.',
          0,
        );
        return;
      }

      final response = await engine.run(
        AgentRuntimeRequest(
          agentId: wf.agentId,
          agentName: agent.name,
          userMessage: wf.prompt,
        ),
        provider: provider,
      ).timeout(const Duration(minutes: 1));

      stopwatch.stop();
      final result = response.finalMessage;

      // Update last run.
      await _repo.updateLastRun(
        wf.id,
        lastRun: DateTime.now(),
        lastResult: result,
        retryCount: 0,
      );

      // Log execution history.
      await _repo.logExecution(WorkflowExecution(
        workflowId: wf.id,
        agentId: wf.agentId,
        workflowTitle: wf.title,
        status: response.success ? 'success' : 'failed',
        result: result,
        executedAt: DateTime.now(),
        durationMs: stopwatch.elapsedMilliseconds,
      ));

      // Show notification.
      if (wf.notification.showResult) {
        await WorkflowNotificationService.show(
          id: wf.id.hashCode.abs() % 2147483647,
          title: response.success
              ? '✓ Workflow Berhasil'
              : '✗ Workflow Gagal',
          body: response.success
              ? 'Workflow "${wf.title}" berhasil dijalankan.'
              : 'Workflow "${wf.title}" gagal dijalankan.',
          style: wf.notification.style.name,
          payload: 'workflow:${wf.id}',
        );
      }

      // Send to chat if enabled.
      if (wf.sendToChat) {
        await _injectToChat(
          wf.agentId,
          response.success
              ? '✓ Workflow **${wf.title}** berhasil dijalankan.'
              : '✗ Workflow **${wf.title}** gagal dijalankan.',
        );
      }
    } on TimeoutException {
      stopwatch.stop();
      // ignore: avoid_print
      print('[WorkflowRunner] ${wf.title} timed out');
      await _handleFailure(wf, 'Timeout: eksekusi melebihi 1 menit.', stopwatch.elapsedMilliseconds);
    } catch (e, st) {
      stopwatch.stop();
      // ignore: avoid_print
      print('[WorkflowRunner] ${wf.title} error: $e\n$st');
      await _handleFailure(wf, 'Error: $e', stopwatch.elapsedMilliseconds);
    }
  }

  Future<void> _handleFailure(WorkflowModel wf, String error, int durationMs) async {
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
    ));

    // Show failure notification.
    await WorkflowNotificationService.show(
      id: wf.id.hashCode.abs() % 2147483647,
      title: '✗ Workflow Gagal',
      body: 'Workflow "${wf.title}" gagal dijalankan.',
      style: 'normal',
      payload: 'workflow:${wf.id}',
    );

    if (wf.sendToChat) {
      await _injectToChat(
        wf.agentId,
        '✗ Workflow **${wf.title}** gagal dijalankan.',
      );
    }
  }

  /// Inject a message into the agent's chat history.
  Future<void> _injectToChat(String agentId, String message) async {
    try {
      final chatService = ChatHistoryService();
      await chatService.addMessage(
        agentId,
        ChatMessage(
          role: 'assistant',
          content: message,
        ),
      );
    } catch (_) {
      // Best-effort.
    }
  }
}

/// Provider for the workflow runner.
final workflowRunnerProvider = Provider<WorkflowRunner>((ref) {
  return WorkflowRunner(ref);
});
