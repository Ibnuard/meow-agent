import 'package:uuid/uuid.dart';

import '../../../services/agent_runtime/runtime_models.dart';
import '../data/module_repository.dart';
import 'workflow_model.dart';
import 'workflow_repository.dart';

/// Agent tools for workflow management.
class WorkflowTools {
  final WorkflowRepository _repo = WorkflowRepository();

  /// Check if the workflows module is enabled and a specific setting is allowed.
  Future<bool> _isAllowed(String settingKey) async {
    final moduleRepo = ModuleRepository();
    final modules = await moduleRepo.getInstalled();
    final mod = modules.where((m) => m.id == 'workflows').firstOrNull;
    if (mod == null || !mod.enabled) return false;
    return mod.settings[settingKey] ?? true;
  }

  /// Create a new workflow.
  Future<ToolExecutionResult> create({
    required String agentId,
    required Map<String, dynamic> args,
  }) async {
    if (!await _isAllowed('allow_create')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.create',
        error: 'Permission denied: workflow creation is disabled.',
      );
    }

    final title = args['title'] as String?;
    final prompt = args['prompt'] as String?;
    if (title == null || title.isEmpty || prompt == null || prompt.isEmpty) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.create',
        error: 'Missing required fields: title and prompt.',
      );
    }

    // Parse trigger.
    final triggerRaw = args['trigger'] as Map<String, dynamic>?;
    if (triggerRaw == null) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.create',
        error: 'Missing required field: trigger.',
      );
    }

    final trigger = TriggerConfig.fromJson(triggerRaw);

    // Parse notification config (optional).
    final notifRaw = args['notification'] as Map<String, dynamic>?;
    final notif =
        notifRaw != null ? NotifConfig.fromJson(notifRaw) : const NotifConfig();

    final sendToChat = args['send_to_chat'] as bool? ?? false;

    final workflow = WorkflowModel(
      id: 'wf_${const Uuid().v4().substring(0, 8)}',
      agentId: agentId,
      title: title,
      prompt: prompt,
      trigger: trigger,
      notification: notif,
      sendToChat: sendToChat,
      enabled: true,
      createdAt: DateTime.now(),
    );

    final success = await _repo.create(workflow);
    if (!success) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.create',
        error: 'Maximum workflow limit reached (20). Disable or delete existing workflows first.',
      );
    }

    return ToolExecutionResult(
      success: true,
      toolName: 'workflow.create',
      data: {
        'workflowId': workflow.id,
        'title': workflow.title,
        'trigger': workflow.trigger.summary,
        'notification': workflow.notification.style.name,
        'sendToChat': workflow.sendToChat,
      },
      actions: const [
        ResultAction(
          label: 'Open Workflows',
          labelId: 'Buka Workflows',
          icon: 'schedule_rounded',
          type: 'navigate',
          target: '/modules/workflows',
        ),
      ],
    );
  }

  /// List all workflows for the agent.
  Future<ToolExecutionResult> list({
    required String agentId,
  }) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.list',
        error: 'Permission denied: workflow read is disabled.',
      );
    }

    final workflows = await _repo.list(agentId: agentId);
    final items = workflows
        .map((w) => {
              'id': w.id,
              'title': w.title,
              'trigger': w.trigger.summary,
              'enabled': w.enabled,
              'lastRun': w.lastRun?.toIso8601String(),
            })
        .toList();

    return ToolExecutionResult(
      success: true,
      toolName: 'workflow.list',
      data: {'count': items.length, 'workflows': items},
    );
  }

  /// Read a single workflow.
  Future<ToolExecutionResult> read({
    required Map<String, dynamic> args,
  }) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.read',
        error: 'Permission denied: workflow read is disabled.',
      );
    }

    final id = args['id'] as String?;
    if (id == null || id.isEmpty) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.read',
        error: 'Missing required field: id.',
      );
    }

    final workflow = await _repo.read(id);
    if (workflow == null) {
      return ToolExecutionResult(
        success: false,
        toolName: 'workflow.read',
        error: 'Workflow not found: $id',
      );
    }

    return ToolExecutionResult(
      success: true,
      toolName: 'workflow.read',
      data: {
        'id': workflow.id,
        'title': workflow.title,
        'prompt': workflow.prompt,
        'trigger': workflow.trigger.toJson(),
        'triggerSummary': workflow.trigger.summary,
        'notification': workflow.notification.toJson(),
        'sendToChat': workflow.sendToChat,
        'enabled': workflow.enabled,
        'lastRun': workflow.lastRun?.toIso8601String(),
        'lastResult': workflow.lastResult,
      },
    );
  }

  /// Update a workflow.
  Future<ToolExecutionResult> update({
    required Map<String, dynamic> args,
  }) async {
    if (!await _isAllowed('allow_update')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.update',
        error: 'Permission denied: workflow update is disabled.',
      );
    }

    final id = args['id'] as String?;
    if (id == null || id.isEmpty) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.update',
        error: 'Missing required field: id.',
      );
    }

    final existing = await _repo.read(id);
    if (existing == null) {
      return ToolExecutionResult(
        success: false,
        toolName: 'workflow.update',
        error: 'Workflow not found: $id',
      );
    }

    final updated = existing.copyWith(
      title: args['title'] as String? ?? existing.title,
      prompt: args['prompt'] as String? ?? existing.prompt,
      trigger: args['trigger'] != null
          ? TriggerConfig.fromJson(args['trigger'] as Map<String, dynamic>)
          : null,
      notification: args['notification'] != null
          ? NotifConfig.fromJson(args['notification'] as Map<String, dynamic>)
          : null,
      sendToChat: args['send_to_chat'] as bool?,
    );

    await _repo.update(updated);

    return const ToolExecutionResult(
      success: true,
      toolName: 'workflow.update',
      data: {'updated': true},
      actions: [
        ResultAction(
          label: 'Open Workflows',
          labelId: 'Buka Workflows',
          icon: 'schedule_rounded',
          type: 'navigate',
          target: '/modules/workflows',
        ),
      ],
    );
  }

  /// Delete a workflow.
  Future<ToolExecutionResult> delete({
    required Map<String, dynamic> args,
  }) async {
    if (!await _isAllowed('allow_delete')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.delete',
        error: 'Permission denied: workflow delete is disabled.',
      );
    }

    final id = args['id'] as String?;
    if (id == null || id.isEmpty) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.delete',
        error: 'Missing required field: id.',
      );
    }

    final success = await _repo.delete(id);
    if (!success) {
      return ToolExecutionResult(
        success: false,
        toolName: 'workflow.delete',
        error: 'Workflow not found: $id',
      );
    }

    return const ToolExecutionResult(
      success: true,
      toolName: 'workflow.delete',
      data: {'deleted': true},
    );
  }

  /// Toggle workflow enabled/disabled.
  Future<ToolExecutionResult> toggle({
    required Map<String, dynamic> args,
  }) async {
    if (!await _isAllowed('allow_update')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.toggle',
        error: 'Permission denied: workflow update is disabled.',
      );
    }

    final id = args['id'] as String?;
    final enabled = args['enabled'] as bool?;
    if (id == null || enabled == null) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.toggle',
        error: 'Missing required fields: id and enabled.',
      );
    }

    final success = await _repo.toggle(id, enabled);
    if (!success) {
      return ToolExecutionResult(
        success: false,
        toolName: 'workflow.toggle',
        error: 'Workflow not found: $id',
      );
    }

    return ToolExecutionResult(
      success: true,
      toolName: 'workflow.toggle',
      data: {'id': id, 'enabled': enabled},
    );
  }
}
