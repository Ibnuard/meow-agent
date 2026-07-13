import '../../../core/storage/agent_soul_repository.dart';
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
  List<ToolDefinition> get toolDefinitions => [
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
          'Return to base. Brings the user back to the Meow Agent app from any external app launched during agentic mode. '
          'If a message argument is provided, it is delivered as an assistant chat bubble BEFORE returning — this is the '
          'correct way to send gathered data (summaries, reports, extracted text) back to the user after app-agentic tasks. '
          'Using message eliminates the need for a separate chat.send call.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'message':
            'string (optional — markdown content to deliver to chat before returning. Use this to send summaries, reports, '
            'or any content gathered during agentic mode. If omitted, just returns without sending a message.)',
      },
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
          'Read a user file from the current agent workspace folder (Documents/MeowAgent/Agents/{AgentName}/). This is for user-uploaded documents, exports, and PDFs — NOT for identity or memory (those live in the database; use system.profile.update / system.memory.append).',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'file': 'string (required: relative path inside the agent workspace)',
        'section': 'string (optional markdown section title)',
      },
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'system.profile.update',
      description:
          'Update a User Identity/Profile field for the current agent. Writes to the local database (agent_soul table). Use for user name, nickname, timezone, role, language, communication style, design preference, and persona/personality.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'field':
            'string (required: ${AgentSoulRepository.profileFields.join('|')}; use these API field keys exactly. SQLite columns user_name/user_nickname map to name/nickname but are not valid field args)',
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
          'Append a concise long-term fact or preference to the local database (agent_memory table). Never store secrets.',
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
        // The handler returns memoryId (the inserted row id) — its presence
        // proves the DB insert landed. Must match the actual payload keys in
        // system_tools_workspace.dart executeMemoryAppend (NOT 'entry').
        expectedDataKeys: ['memoryId'],
      ),
    ),
    ToolDefinition(
      name: 'system.memory.search',
      description:
          'Search long-term memory entries by keyword or category. Returns matching entries from the agent_memory table. Use this to proactively recall relevant context before answering or planning.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'query': 'string (optional: substring search over memory content)',
        'category':
            'string (optional: fact|preference|bookmark|session — filter by category)',
        'limit': 'int (optional, default 20, max 50)',
      },
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'system.config.read',
      description:
          'Read the master app configuration. Returns agents, providers (no API keys), modules, active selections, and user preferences. Live data is merged from the local database.',
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
          'Apply JSON Patch-style operations to non-entity configuration (modules, prefs, active selections). For agents and providers, use the dedicated tools (agent.create / agent.delete / agent.update / provider.create / provider.delete / provider.update) — patching /agents or /providers is rejected.',
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
          'Export a JSON snapshot of agents, providers (no API keys), and module settings. The result is returned in tool data for backup or transfer purposes.',
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
      appSettings: ctx.appSettings,
      moduleEntries: ctx.moduleEntries,
      agentRepository: ctx.agentRepository,
      providerRepository: ctx.providerRepository,
      saveAgent: ctx.saveAgent,
      deleteAgent: ctx.deleteAgent,
      toolDefinitions: ctx.allToolDefinitions,
      coreSoulRepo: ctx.coreSoulRepo,
      coreMemoryRepo: ctx.coreMemoryRepo,
    );
    switch (request.name) {
      case 'system.self':
        return tools.executeSelf();
      case 'system.rtb':
        return tools.executeReturnToBase(request.args, ctx);
      case 'system.workspace.schema':
        return tools.executeWorkspaceSchema();
      case 'system.workspace.read':
        return tools.executeWorkspaceRead(request.args);
      case 'system.profile.update':
        return tools.executeProfileUpdate(request.args);
      case 'system.memory.append':
        return tools.executeMemoryAppend(request.args);
      case 'system.memory.search':
        return tools.executeMemorySearch(request.args);
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
