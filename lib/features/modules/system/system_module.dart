import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import '../../../services/agent_runtime/system_tools.dart';

/// System module: agent/provider/module introspection + management, profile
/// and durable memory writes, workspace introspection, export/import.
class SystemModulePlugin extends ModulePlugin {
  const SystemModulePlugin();

  @override
  String get moduleId => 'system';

  @override
  String get catalogGroup => 'system';

  @override
  List<String> get capabilityHints => const [
    'agent',
    'agents',
    'provider',
    'module',
    'modules',
    'tool',
    'tools',
    'workspace',
    'memory',
    'profile',
    'identity',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'system.self',
      description:
          'Inspect the current agent identity, provider, workspace path, core markdown files, and capability counts.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'system.rtb',
      description:
          'Return to base. Brings the user back to the Meow Agent app from any external app launched during agentic mode (after app_agent.* operations). Use this as the FINAL step when the task involves opening an external app and then delivering a result back. No confirmation needed — this returns to the app the user is already chatting in.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    ToolDefinition(
      name: 'system.workspace.schema',
      description:
          'Describe the Meow Agent markdown model: system markdown standard vs mutable per-agent workspace markdown.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'system.workspace.read',
      description:
          'Read one core markdown file from the current agent workspace. Use for SOUL.md, MEMORY.md, SKILLS.md, or HEARTBEAT.md.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'file': 'string (required: SOUL.md|MEMORY.md|SKILLS.md|HEARTBEAT.md)',
        'section': 'string (optional markdown section title)',
      },
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'system.profile.update',
      description:
          'Update a specific User Identity/Profile field in the current agent workspace SOUL.md. Use for user name, nickname, timezone, role, language, and communication style.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'field':
            'string (required: name|nickname|preferred_language|timezone|work_role|main_project|communication_style|design_preference)',
        'value': 'string (required)',
      },
      operation: 'update',
      targetEntity: 'profile',
      selectorArgs: ['field'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'profile',
        expectedDataKeys: ['field'],
      ),
    ),
    ToolDefinition(
      name: 'system.memory.append',
      description:
          'Append a concise long-term fact or preference to the current agent workspace MEMORY.md. Never store secrets.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'content': 'string (required)',
        'category':
            'string (optional: fact|preference|bookmark|session, default fact)',
      },
      operation: 'create',
      targetEntity: 'memory',
      selectorArgs: ['content'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'memory',
        expectedDataKeys: ['entry'],
      ),
    ),
    ToolDefinition(
      name: 'system.config.read',
      description:
          'Read the master app configuration from meow.json. Use this before configuration changes or when inspecting agents, providers, modules, active selections, and user preferences.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'path': r'string (optional JSON path, default $)',
        'includeSecrets': 'bool (optional, always false for provider keys)',
      },
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'system.config.patch',
      description:
          'Apply JSON Patch-style operations to meow.json for configurational state changes. The runtime backs up, validates, writes atomically, reloads, and verifies config state.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'operations': 'array (required, items: {op,path,value})',
        'reason': 'string (optional human-readable reason)',
      },
      operation: 'update',
      targetEntity: 'config',
      selectorArgs: ['operations'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'config',
        expectedDataKeys: ['backupId', 'changedPaths', 'configHash'],
      ),
    ),
    ToolDefinition(
      name: 'system.tools.list',
      description:
          'List registered runtime tools, risk levels, confirmation requirements, and current module permission availability.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'system.export_all',
      description:
          'Export a JSON snapshot of agents, providers (no API keys), and module settings. The result is returned in tool data; runtime caller can write it to a file via files.write for backup.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    ToolDefinition(
      name: 'system.import',
      description:
          'Restore from a snapshot produced by system.export_all. Mode "merge" adds missing entries (default). Mode "replace" wipes existing agents (except current) and modules first. Provider API keys are NOT in snapshots and must be re-entered manually.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'snapshot': 'object (required, JSON output from system.export_all)',
        'mode': 'string (optional: merge | replace. default merge)',
      },
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) {
    final tools = SystemTools(
      agentId: ctx.agentId,
      agentName: ctx.agentName,
      moduleRepository: ctx.moduleRepository,
      configRepository: ctx.configRepository,
      agentRepository: ctx.agentRepository,
      providerRepository: ctx.providerRepository,
      saveAgent: ctx.saveAgent,
      deleteAgent: ctx.deleteAgent,
      toolDefinitions: ctx.allToolDefinitions,
    );
    switch (request.name) {
      case 'system.self':
        return tools.executeSelf();
      case 'system.rtb':
        return tools.executeReturnToBase();
      case 'system.workspace.schema':
        return tools.executeWorkspaceSchema();
      case 'system.workspace.read':
        return tools.executeWorkspaceRead(request.args);
      case 'system.profile.update':
        return tools.executeProfileUpdate(request.args);
      case 'system.memory.append':
        return tools.executeMemoryAppend(request.args);
      case 'system.config.read':
        return tools.executeConfigRead(request.args);
      case 'system.config.patch':
        return tools.executeConfigPatch(request.args);
      case 'system.tools.list':
        return tools.executeToolsList();
      case 'system.export_all':
        return tools.executeExportAll();
      case 'system.import':
        return tools.executeImport(request.args);
      default:
        return Future.value(
          ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'SystemModulePlugin cannot handle ${request.name}',
          ),
        );
    }
  }
}
