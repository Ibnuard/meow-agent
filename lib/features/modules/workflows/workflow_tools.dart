import 'package:uuid/uuid.dart';

import '../../../services/agent_runtime/runtime_models.dart';
import '../data/module_repository.dart';
import 'workflow_model.dart';
import 'workflow_repository.dart';
import 'workflow_templates.dart';

/// Agent tools for workflow management.
class WorkflowTools {
  WorkflowTools({ModuleRepository? moduleRepository})
    : _moduleRepository = moduleRepository ?? ModuleRepository();

  final WorkflowRepository _repo = WorkflowRepository();
  final ModuleRepository _moduleRepository;

  /// Check if the workflows module is enabled and a specific setting is allowed.
  Future<bool> _isAllowed(String settingKey) async {
    final modules = await _moduleRepository.getInstalled();
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

    // Parse steps (optional).
    final stepsRaw = args['steps'] as List?;
    final steps = <WorkflowStep>[];
    if (stepsRaw != null) {
      for (var i = 0; i < stepsRaw.length; i++) {
        final s = stepsRaw[i];
        if (s is Map<String, dynamic>) {
          steps.add(
            WorkflowStep(
              id: s['id'] as String? ?? 'step_${i + 1}',
              prompt: s['prompt'] as String? ?? '',
              condition: s['condition'] as String?,
              onFailure: StepFailureAction.values.firstWhere(
                (a) => a.name == s['onFailure'],
                orElse: () => StepFailureAction.stop,
              ),
              timeoutSeconds: s['timeoutSeconds'] as int? ?? 60,
            ),
          );
        }
      }
    }

    if (title == null || title.isEmpty) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.create',
        error: 'Missing required field: title.',
      );
    }
    if (steps.isEmpty && (prompt == null || prompt.isEmpty)) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.create',
        error: 'Either prompt or steps must be provided.',
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
    final notif = notifRaw != null
        ? NotifConfig.fromJson(notifRaw)
        : const NotifConfig();
    final sendToChat = args['send_to_chat'] as bool? ?? false;

    // Parse priority.
    final priority = WorkflowPriority.values.firstWhere(
      (p) => p.name == args['priority'],
      orElse: () => WorkflowPriority.normal,
    );

    // Parse variables.
    final variablesRaw = args['variables'] as Map<String, dynamic>?;
    final variables = <String, String>{};
    variablesRaw?.forEach((k, v) => variables[k] = v.toString());

    final workflow = WorkflowModel(
      id: 'wf_${const Uuid().v4().substring(0, 8)}',
      agentId: agentId,
      title: title,
      prompt: prompt ?? '',
      trigger: trigger,
      notification: notif,
      sendToChat: sendToChat,
      enabled: true,
      priority: priority,
      timeoutSeconds: args['timeout_seconds'] as int? ?? 60,
      steps: steps,
      variables: variables,
      templateId: args['template_id'] as String?,
      createdAt: DateTime.now(),
    );

    final success = await _repo.create(workflow);
    if (!success) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.create',
        error: 'Maximum workflow limit reached (20).',
      );
    }

    return ToolExecutionResult(
      success: true,
      toolName: 'workflow.create',
      data: {
        'workflowId': workflow.id,
        'title': workflow.title,
        'trigger': workflow.trigger.summary,
        'priority': workflow.priority.name,
        'isChained': workflow.isChained,
        'stepCount': workflow.steps.length,
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

  /// Create from a template.
  Future<ToolExecutionResult> createFromTemplate({
    required String agentId,
    required Map<String, dynamic> args,
  }) async {
    if (!await _isAllowed('allow_create')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.create_from_template',
        error: 'Permission denied: workflow creation is disabled.',
      );
    }

    final templateId = args['template_id'] as String?;
    if (templateId == null) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.create_from_template',
        error: 'Missing required field: template_id.',
      );
    }

    final tpl = WorkflowTemplateRegistry.byId(templateId);
    if (tpl == null) {
      return ToolExecutionResult(
        success: false,
        toolName: 'workflow.create_from_template',
        error: 'Template not found: $templateId',
      );
    }

    final workflow = WorkflowModel(
      id: 'wf_${const Uuid().v4().substring(0, 8)}',
      agentId: agentId,
      title: tpl.titleId,
      prompt: tpl.defaultPrompt,
      trigger:
          tpl.defaultTrigger ??
          const TriggerConfig(type: TriggerType.interval, intervalMinutes: 60),
      enabled: true,
      priority: tpl.defaultPriority,
      timeoutSeconds: tpl.defaultTimeoutSeconds,
      steps: tpl.defaultSteps,
      variables: tpl.defaultVariables,
      templateId: tpl.id,
      createdAt: DateTime.now(),
    );

    final success = await _repo.create(workflow);
    if (!success) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.create_from_template',
        error: 'Maximum workflow limit reached (20).',
      );
    }

    return ToolExecutionResult(
      success: true,
      toolName: 'workflow.create_from_template',
      data: {
        'workflowId': workflow.id,
        'templateId': tpl.id,
        'title': workflow.title,
      },
    );
  }

  /// List available templates.
  Future<ToolExecutionResult> listTemplates() async {
    final templates = WorkflowTemplateRegistry.templates;
    final items = templates
        .map(
          (t) => {
            'id': t.id,
            'title': t.titleId,
            'description': t.descriptionId,
            'category': t.category.name,
            'icon': t.icon,
            'isChained': t.defaultSteps.isNotEmpty,
          },
        )
        .toList();

    return ToolExecutionResult(
      success: true,
      toolName: 'workflow.list_templates',
      data: {'count': items.length, 'templates': items},
    );
  }

  /// List workflows. Defaults to ALL workflows across the app (matching the
  /// Workflows UI). Pass `assignedTo` (agent id or name) to scope to one
  /// agent. `callerAgentId` is logged for traceability but does NOT filter.
  Future<ToolExecutionResult> list({
    required String callerAgentId,
    Map<String, dynamic> args = const {},
  }) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'workflow.list',
        error: 'Permission denied: workflow read is disabled.',
      );
    }

    final workflows = await _repo.list();
    final assignedTo = (args['assignedTo'] as String? ?? '').trim();
    final filtered = assignedTo.isEmpty
        ? workflows
        : workflows
            .where((w) =>
                w.agentId.toLowerCase() == assignedTo.toLowerCase())
            .toList();

    final items = filtered
        .map(
          (w) => {
            'id': w.id,
            'title': w.title,
            'trigger': w.trigger.summary,
            'enabled': w.enabled,
            'assignedAgentId': w.agentId,
            'lastRun': w.lastRun?.toIso8601String(),
            'priority': w.priority.name,
            'isChained': w.isChained,
            'stepCount': w.steps.length,
          },
        )
        .toList();

    return ToolExecutionResult(
      success: true,
      toolName: 'workflow.list',
      data: {
        'count': items.length,
        'totalCount': workflows.length,
        'callerAgentId': callerAgentId,
        if (assignedTo.isNotEmpty) 'filteredBy': assignedTo,
        'workflows': items,
      },
    );
  }

  /// Read a single workflow.
  Future<ToolExecutionResult> read({required Map<String, dynamic> args}) async {
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
        'priority': workflow.priority.name,
        'timeoutSeconds': workflow.timeoutSeconds,
        'steps': workflow.steps.map((s) => s.toJson()).toList(),
        'variables': workflow.variables,
        'templateId': workflow.templateId,
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

    // Parse steps if provided.
    List<WorkflowStep>? newSteps;
    final stepsRaw = args['steps'] as List?;
    if (stepsRaw != null) {
      newSteps = [];
      for (var i = 0; i < stepsRaw.length; i++) {
        final s = stepsRaw[i];
        if (s is Map<String, dynamic>) {
          newSteps.add(
            WorkflowStep(
              id: s['id'] as String? ?? 'step_${i + 1}',
              prompt: s['prompt'] as String? ?? '',
              condition: s['condition'] as String?,
              onFailure: StepFailureAction.values.firstWhere(
                (a) => a.name == s['onFailure'],
                orElse: () => StepFailureAction.stop,
              ),
              timeoutSeconds: s['timeoutSeconds'] as int? ?? 60,
            ),
          );
        }
      }
    }

    // Parse variables if provided.
    Map<String, String>? newVariables;
    final variablesRaw = args['variables'] as Map<String, dynamic>?;
    if (variablesRaw != null) {
      newVariables = {};
      variablesRaw.forEach((k, v) => newVariables![k] = v.toString());
    }

    WorkflowPriority? newPriority;
    if (args['priority'] != null) {
      newPriority = WorkflowPriority.values.firstWhere(
        (p) => p.name == args['priority'],
        orElse: () => existing.priority,
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
      priority: newPriority,
      timeoutSeconds: args['timeout_seconds'] as int?,
      steps: newSteps,
      variables: newVariables,
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
