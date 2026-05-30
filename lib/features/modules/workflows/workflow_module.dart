import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'workflow_tools.dart';

/// Workflow module: create/list/read/update/delete/toggle scheduled or
/// event-triggered automations, plus templates.
class WorkflowModulePlugin extends ModulePlugin {
  const WorkflowModulePlugin();

  @override
  String get moduleId => 'workflow';

  @override
  String get catalogGroup => 'workflow';

  @override
  List<String> get capabilityHints => const [
    'workflow',
    'automation',
    'schedule',
    'recurring',
    'cron',
    'trigger',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'workflow.create',
      description:
          'Create a scheduled, interval, or event-triggered workflow. Supports single-prompt or chained multi-step execution.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'title': 'string (required)',
        'prompt': 'string (required if steps not provided)',
        'agentId':
            'string (optional, defaults to caller agent; accepts agent UUID or display name to assign workflow to a specific agent)',
        'trigger':
            'object (required) - {type: schedule|interval|event, hour, minute, daysOfWeek, intervalMinutes, eventKind: batteryLow|batteryAbove|batteryFull|chargingStart|chargingStop|notificationKeyword|appOpened|wifiConnected|wifiDisconnected, eventParams: {keyword, package}}',
        'notification':
            'object (optional) - {style: silent|normal|alarm, showResult: bool}',
        'send_to_chat': 'bool (optional, default false)',
        'priority': 'string (optional) - low|normal|high|critical',
        'timeout_seconds': 'int (optional, default 60)',
        'steps':
            'list<object> (optional) - [{id, prompt, condition?, onFailure: stop|skip|retry, timeoutSeconds}]',
        'variables':
            'object (optional) - {key: defaultValue} accessed in prompts as {{key}}',
      },
      operation: 'create',
      targetEntity: 'workflow',
      selectorArgs: ['title'],
      postconditions: {'workflow_present': 'title'},
      verificationProbe: ToolVerificationProbe(
        kind: 'snapshot_contains',
        entityType: 'workflow',
        expectPresent: true,
        selectorArgKey: 'title',
      ),
    ),
    ToolDefinition(
      name: 'workflow.create_from_template',
      description:
          'Create a workflow from a pre-built template. Use workflow.list_templates to see available templates.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'template_id': 'string (required)'},
    ),
    ToolDefinition(
      name: 'workflow.list_templates',
      description:
          'List all available workflow templates with their categories and metadata.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'workflow.list',
      description:
          'List workflows. By default returns ALL workflows across the app, '
          'matching what the user sees in the Workflows screen. Pass '
          '"assignedTo" (agent id or name) to filter to one agent.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'assignedTo': 'string (optional, agent id or name to filter on)',
      },
      operation: 'list',
      targetEntity: 'workflow',
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'workflow.read',
      description:
          'Read details of a specific workflow including steps and variables.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'id': 'string (required)'},
      operation: 'read',
      targetEntity: 'workflow',
      selectorArgs: ['id'],
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'workflow.update',
      description: 'Update an existing workflow. Any field can be updated.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'id': 'string (required)',
        'agentId':
            'string (optional, accepts agent UUID or display name to re-assign the workflow to another agent)',
        'title': 'string (optional)',
        'prompt': 'string (optional)',
        'trigger': 'object (optional)',
        'notification': 'object (optional)',
        'send_to_chat': 'bool (optional)',
        'priority': 'string (optional)',
        'timeout_seconds': 'int (optional)',
        'steps': 'list<object> (optional)',
        'variables': 'object (optional)',
      },
      operation: 'update',
      targetEntity: 'workflow',
      selectorArgs: ['id', 'title'],
      postconditions: {'workflow_updated': 'id'},
      verificationProbe: ToolVerificationProbe(
        kind: 'snapshot_contains',
        entityType: 'workflow',
        expectPresent: true,
        selectorArgKey: 'id',
      ),
    ),
    ToolDefinition(
      name: 'workflow.delete',
      description: 'Delete a workflow. Requires confirmation.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'id': 'string (required)'},
      operation: 'delete',
      targetEntity: 'workflow',
      selectorArgs: ['id', 'title'],
      postconditions: {'workflow_absent': 'id'},
      verificationProbe: ToolVerificationProbe(
        kind: 'snapshot_absent',
        entityType: 'workflow',
        expectPresent: false,
        selectorArgKey: 'id',
      ),
    ),
    ToolDefinition(
      name: 'workflow.toggle',
      description: 'Enable or disable a workflow.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'id': 'string (required)', 'enabled': 'bool (required)'},
      operation: 'toggle',
      targetEntity: 'workflow',
      selectorArgs: ['id', 'title'],
      postconditions: {'workflow_enabled': 'enabled'},
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) {
    final tools = WorkflowTools(
      moduleRepository: ctx.moduleRepository,
      agentRepository: ctx.agentRepository,
    );
    // Workflow tools resolve the owning agent by id, falling back to name.
    final ownerId = ctx.agentId.isNotEmpty ? ctx.agentId : ctx.agentName;
    switch (request.name) {
      case 'workflow.create':
        return tools.create(agentId: ownerId, args: request.args);
      case 'workflow.create_from_template':
        return tools.createFromTemplate(agentId: ownerId, args: request.args);
      case 'workflow.list_templates':
        return tools.listTemplates();
      case 'workflow.list':
        return tools.list(callerAgentId: ownerId, args: request.args);
      case 'workflow.read':
        return tools.read(args: request.args);
      case 'workflow.update':
        return tools.update(args: request.args);
      case 'workflow.delete':
        return tools.delete(args: request.args);
      case 'workflow.toggle':
        return tools.toggle(args: request.args);
      default:
        return Future.value(
          ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'WorkflowModulePlugin cannot handle ${request.name}',
          ),
        );
    }
  }
}
