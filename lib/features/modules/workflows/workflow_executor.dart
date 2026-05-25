import 'dart:async';

import '../../../services/agent_runtime/runtime_models.dart';
import '../../chat/data/chat_history_service.dart';
import 'workflow_model.dart';
import 'workflow_notification_service.dart';
import 'workflow_repository.dart';

/// Max execution time for a single workflow prompt.
const _executionTimeout = Duration(minutes: 1);

/// Max retry attempts before marking as failed.
const _maxRetries = 20;

/// Delay between retries.
const _retryDelay = Duration(minutes: 1);

/// Executes workflow prompts headlessly and delivers results.
class WorkflowExecutor {
  final WorkflowRepository _repo = WorkflowRepository();

  /// Execute a workflow's prompt and handle result delivery.
  /// [runPrompt] is injected to avoid circular dependency on RuntimeEngine.
  Future<void> execute(
    WorkflowModel workflow, {
    required Future<AgentRuntimeResponse> Function(String agentId, String prompt)
        runPrompt,
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      // Execute with timeout.
      final response = await runPrompt(workflow.agentId, workflow.prompt)
          .timeout(_executionTimeout);
      stopwatch.stop();

      final result = response.finalMessage;
      final success = response.success;

      if (success) {
        await _onSuccess(workflow, result, stopwatch.elapsedMilliseconds);
      } else {
        await _onFailure(workflow, result, stopwatch.elapsedMilliseconds);
      }
    } on TimeoutException {
      stopwatch.stop();
      await _onFailure(
        workflow,
        'Execution timed out (max ${_executionTimeout.inSeconds}s).',
        stopwatch.elapsedMilliseconds,
      );
    } catch (e) {
      stopwatch.stop();
      await _onFailure(
        workflow,
        'Error: $e',
        stopwatch.elapsedMilliseconds,
      );
    }
  }

  Future<void> _onSuccess(
    WorkflowModel workflow,
    String result,
    int durationMs,
  ) async {
    // Update last run.
    await _repo.updateLastRun(
      workflow.id,
      lastRun: DateTime.now(),
      lastResult: result,
      retryCount: 0,
    );

    // Log execution history.
    await _repo.logExecution(WorkflowExecution(
      workflowId: workflow.id,
      agentId: workflow.agentId,
      workflowTitle: workflow.title,
      status: 'success',
      result: result,
      executedAt: DateTime.now(),
      durationMs: durationMs,
    ));

    // Show notification.
    if (workflow.notification.showResult) {
      await WorkflowNotificationService.show(
        id: workflow.id.hashCode.abs(),
        title: '✓ ${workflow.title}',
        body: result,
        style: workflow.notification.style.name,
        payload: 'agent:${workflow.agentId}',
      );
    }

    // Send to chat if enabled.
    if (workflow.sendToChat) {
      await _injectToChat(workflow.agentId, result);
    }
  }

  Future<void> _onFailure(
    WorkflowModel workflow,
    String error,
    int durationMs,
  ) async {
    final newRetryCount = workflow.retryCount + 1;

    if (newRetryCount >= _maxRetries) {
      // Max retries reached — mark as permanently failed.
      await _repo.updateLastRun(
        workflow.id,
        lastRun: DateTime.now(),
        lastResult: 'FAILED: $error',
        retryCount: 0, // Reset for next cycle.
      );

      // Log failure.
      await _repo.logExecution(WorkflowExecution(
        workflowId: workflow.id,
        agentId: workflow.agentId,
        workflowTitle: workflow.title,
        status: 'failed',
        result: error,
        executedAt: DateTime.now(),
        durationMs: durationMs,
      ));

      // Send failure notification.
      await WorkflowNotificationService.show(
        id: workflow.id.hashCode.abs(),
        title: '✗ ${workflow.title} — Gagal',
        body: 'Workflow gagal setelah $_maxRetries percobaan.\n$error',
        style: 'normal',
        payload: 'agent:${workflow.agentId}',
      );

      // Send failure report to chat.
      if (workflow.sendToChat) {
        await _injectToChat(
          workflow.agentId,
          '⚠️ Workflow "${workflow.title}" gagal setelah $_maxRetries percobaan: $error',
        );
      }
    } else {
      // Update retry count and schedule retry.
      await _repo.updateLastRun(
        workflow.id,
        lastRun: DateTime.now(),
        lastResult: 'Retrying ($newRetryCount/$_maxRetries): $error',
        retryCount: newRetryCount,
      );

      // Log retry attempt.
      await _repo.logExecution(WorkflowExecution(
        workflowId: workflow.id,
        agentId: workflow.agentId,
        workflowTitle: workflow.title,
        status: 'retry',
        result: 'Attempt $newRetryCount: $error',
        executedAt: DateTime.now(),
        durationMs: durationMs,
      ));

      // Wait and retry.
      await Future.delayed(_retryDelay);
      final refreshed = await _repo.read(workflow.id);
      if (refreshed != null && refreshed.enabled) {
        await execute(refreshed, runPrompt: _lastRunPrompt!);
      }
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
          content: '📋 **Workflow Report**\n\n$message',
        ),
      );
    } catch (_) {
      // Chat injection is best-effort.
    }
  }

  // Store reference for retry recursion.
  Future<AgentRuntimeResponse> Function(String, String)? _lastRunPrompt;

  /// Entry point with runPrompt stored for retries.
  Future<void> run(
    WorkflowModel workflow, {
    required Future<AgentRuntimeResponse> Function(String agentId, String prompt)
        runPrompt,
  }) async {
    _lastRunPrompt = runPrompt;
    await execute(workflow, runPrompt: runPrompt);
    _lastRunPrompt = null;
  }
}
