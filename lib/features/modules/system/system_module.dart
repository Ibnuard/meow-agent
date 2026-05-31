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
      name: 'system.agents.list',
      description: 'List all configured agents and their public provider info.',
      risk: 'safe',
      requiresConfirmation: false,
      operation: 'list',
      targetEntity: 'agent',
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'system.agents.create',
      description:
          'Create a new agent and generate its workspace markdown from the system standard template. Pass persona/role/description to bake the agent’s personality into its SOUL.md in the same call.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'name': 'string (required)',
        'providerId':
            'string (optional if exactly one provider exists; otherwise required)',
        'model':
            'string (optional; one of the selected provider models, defaults to provider default)',
        'maxContextLength': 'int (optional, default 8191)',
        'iconKey': 'string (optional)',
        'colorKey': 'string (optional)',
        'role':
            'string (optional, short role/title e.g. "Skillful coder agent")',
        'persona':
            'string (optional, 2-4 sentence personality description for SOUL.md Agent Identity)',
        'communicationStyle':
            'string (optional, e.g. "concise, technical, code-first")',
      },
      operation: 'create',
      targetEntity: 'agent',
      selectorArgs: ['name'],
      postconditions: {'agent_present': 'name'},
      verificationProbe: ToolVerificationProbe(
        kind: 'snapshot_contains',
        entityType: 'agent',
        expectPresent: true,
        selectorArgKey: 'name',
      ),
    ),
    ToolDefinition(
      name: 'system.agents.delete',
      description:
          'Delete an agent and its workspace. Cannot delete the current active agent from its own chat. ALWAYS pass `name` (preferred) and `id` together when known — names are user-visible and stable; ids are opaque hashes that may not match across mutating ops in the same multi-step task. The handler resolves by id first, then falls back to name (case-insensitive).',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'name':
            'string (preferred; case-insensitive match on the agent display name)',
        'id':
            'string (optional fallback; only reliable when produced by a system.agents.list call in the SAME planning round)',
      },
      operation: 'delete',
      targetEntity: 'agent',
      selectorArgs: ['id', 'agentId', 'name'],
      policies: ['deny_current_agent'],
      postconditions: {'agent_absent': 'name'},
      verificationProbe: ToolVerificationProbe(
        kind: 'snapshot_absent',
        entityType: 'agent',
        expectPresent: false,
        selectorArgKey: 'name',
      ),
    ),
    ToolDefinition(
      name: 'system.providers.list',
      description:
          'List configured LLM providers with public fields only. API keys are never returned.',
      risk: 'safe',
      requiresConfirmation: false,
      operation: 'list',
      targetEntity: 'provider',
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'system.modules.list',
      description:
          'List available and installed modules, enabled state, and module setting toggles.',
      risk: 'safe',
      requiresConfirmation: false,
      operation: 'list',
      targetEntity: 'module',
      isRetrieval: true,
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
      name: 'system.modules.toggle',
      description:
          'Enable/disable an installed module or one of its setting toggles. Pass settingKey to flip a per-feature switch (e.g. allow_create on notes). Without settingKey, toggles the module-level enabled flag.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'moduleId': 'string (required, e.g. notes/files/calendar)',
        'settingKey':
            'string (optional, specific permission key from module settings)',
        'enabled':
            'bool (optional, explicit target state; if omitted, toggles current)',
      },
      operation: 'update',
      targetEntity: 'module',
      selectorArgs: ['moduleId', 'settingKey'],
    ),
    ToolDefinition(
      name: 'system.agents.update',
      description:
          'Update an existing agent: rename, swap provider, change icon/color, or change context length. Pass id (preferred) or name to identify, then any combination of newName/providerId/maxContextLength/iconKey/colorKey.',
      risk: 'sensitive-lite',
      requiresConfirmation: true,
      inputSchema: {
        'id': 'string (preferred, agent id)',
        'name': 'string (fallback, agent name)',
        'newName': 'string (optional)',
        'providerId':
            'string (optional, provider id or nickname for re-binding)',
        'model':
            'string (optional; select a model from the current/new provider)',
        'maxContextLength': 'int (optional)',
        'iconKey': 'string (optional)',
        'colorKey': 'string (optional)',
      },
      operation: 'update',
      targetEntity: 'agent',
      selectorArgs: ['id', 'name'],
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
      agentRepository: ctx.agentRepository,
      providerRepository: ctx.providerRepository,
      saveAgent: ctx.saveAgent,
      deleteAgent: ctx.deleteAgent,
      toolDefinitions: ctx.allToolDefinitions,
    );
    switch (request.name) {
      case 'system.self':
        return tools.executeSelf();
      case 'system.workspace.schema':
        return tools.executeWorkspaceSchema();
      case 'system.workspace.read':
        return tools.executeWorkspaceRead(request.args);
      case 'system.profile.update':
        return tools.executeProfileUpdate(request.args);
      case 'system.memory.append':
        return tools.executeMemoryAppend(request.args);
      case 'system.agents.list':
        return tools.executeAgentsList();
      case 'system.agents.create':
        return tools.executeAgentsCreate(request.args);
      case 'system.agents.delete':
        return tools.executeAgentsDelete(request.args);
      case 'system.providers.list':
        return tools.executeProvidersList();
      case 'system.modules.list':
        return tools.executeModulesList();
      case 'system.tools.list':
        return tools.executeToolsList();
      case 'system.modules.toggle':
        return tools.executeModulesToggle(request.args);
      case 'system.agents.update':
        return tools.executeAgentsUpdate(request.args);
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
