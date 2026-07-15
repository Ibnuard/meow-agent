import '../../../core/storage/agent_skills_repository.dart';
import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';

/// Domain tool module for skill CRUD operations.
///
/// Exposes `skills.*` tools so the agent can list, search, create, update,
/// and delete skills assigned to the current agent (or globally). Without
/// this plugin, skills were only injected as text context — the agent had
/// no callable tool surface to manage them.
class SkillsModulePlugin extends ModulePlugin {
  const SkillsModulePlugin();

  @override
  String get moduleId => 'skills';

  @override
  String get catalogGroup => 'system';

  @override
  List<String> get capabilityHints => const [
    'skill',
    'skills',
    'guideline',
    'guidelines',
    'instruction',
    'instructions',
    'create skill',
    'delete skill',
    'list skills',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'skills.list',
      description:
          'List all active skills assigned to the current agent. Returns id, title, '
          'a content preview (first 200 chars), and enabled status. Use this when '
          'the user asks what skills/guidelines they have or what the agent can do.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'skills.search',
      description:
          'Search skills by keyword in title or content. Returns matching skills '
          'with id, title, and content preview. Use when the user asks about a '
          'specific topic or capability.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'query': 'string (required: keyword to search in title and content)',
      },
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'skills.create',
      description:
          'Create a new skill/guideline with a title and markdown content. '
          'The skill is assigned to the current agent by default. '
          'Returns the created skill entity.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'title': 'string (required, short descriptive name)',
        'content': 'string (required, markdown body of the skill/guideline)',
        'github_url': 'string (optional, source URL if the skill came from GitHub)',
      },
      operation: 'create',
      targetEntity: 'skill',
      selectorArgs: ['title'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'skill',
        expectedDataKeys: ['id', 'title'],
      ),
    ),
    ToolDefinition(
      name: 'skills.update',
      description:
          'Update the title or content of an existing skill by id. '
          'Returns the updated skill entity.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'id': 'string (required, skill id to update)',
        'title': 'string (optional, new title)',
        'content': 'string (optional, new markdown content)',
      },
      operation: 'update',
      targetEntity: 'skill',
      selectorArgs: ['id'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'skill',
        expectedDataKeys: ['id', 'title'],
      ),
    ),
    ToolDefinition(
      name: 'skills.delete',
      description:
          'Delete a skill by id. Removes it from all agents. '
          'Cannot be undone.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'id': 'string (required, skill id to delete)',
      },
      operation: 'delete',
      targetEntity: 'skill',
      selectorArgs: ['id'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'skill',
        expectedDataKeys: ['deleted', 'id'],
      ),
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreSkillsRepo;
    if (repo == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Skills repository not available.',
      );
    }

    switch (request.name) {
      case 'skills.list':
        return _list(request, ctx);
      case 'skills.search':
        return _search(request, ctx);
      case 'skills.create':
        return _create(request, ctx);
      case 'skills.update':
        return _update(request, ctx);
      case 'skills.delete':
        return _delete(request, ctx);
      default:
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'Unknown skills tool: ${request.name}',
        );
    }
  }

  Future<ToolExecutionResult> _list(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreSkillsRepo!;
    final skills = await repo.getActiveSkillsForAgent(ctx.agentId);
    if (skills.isEmpty) {
      return ToolExecutionResult(
        success: true,
        toolName: request.name,
        data: {
          'count': 0,
          'skills': <Map<String, dynamic>>[],
        },
      );
    }
    final list = skills.map((s) => _toSummary(s)).toList();
    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: {
        'count': list.length,
        'skills': list,
      },
    );
  }

  Future<ToolExecutionResult> _search(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreSkillsRepo!;
    final query = (request.args['query'] ?? '').toString().trim().toLowerCase();
    if (query.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Search query is required.',
      );
    }
    final all = await repo.getActiveSkillsForAgent(ctx.agentId);
    final matched = all.where((s) {
      return s.title.toLowerCase().contains(query) ||
          s.content.toLowerCase().contains(query);
    }).toList();
    final list = matched.map((s) => _toSummary(s)).toList();
    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: {
        'count': list.length,
        'query': query,
        'skills': list,
      },
    );
  }

  Future<ToolExecutionResult> _create(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreSkillsRepo!;
    final title = (request.args['title'] ?? '').toString().trim();
    final content = (request.args['content'] ?? '').toString().trim();
    if (title.isEmpty || content.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Title and content are required.',
      );
    }
    final githubUrl = (request.args['github_url'] ?? '').toString().trim();

    final id = 'skill_${DateTime.now().millisecondsSinceEpoch}';
    final skill = AgentSkill(
      id: id,
      title: title,
      content: content,
      githubUrl: githubUrl.isEmpty ? null : githubUrl,
      isEnabled: true,
      createdAt: DateTime.now(),
      assignedAgentIds: [ctx.agentId],
    );
    await repo.save(skill);
    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: _toMap(skill),
    );
  }

  Future<ToolExecutionResult> _update(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreSkillsRepo!;
    final id = (request.args['id'] ?? '').toString().trim();
    if (id.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Skill id is required.',
      );
    }
    final existing = await repo.getById(id);
    if (existing == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Skill not found: $id',
      );
    }
    final title = request.args['title']?.toString().trim();
    final content = request.args['content']?.toString().trim();
    final updated = existing.copyWith(
      title: (title != null && title.isNotEmpty) ? title : null,
      content: (content != null && content.isNotEmpty) ? content : null,
    );
    await repo.save(updated);
    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: _toMap(updated),
    );
  }

  Future<ToolExecutionResult> _delete(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreSkillsRepo!;
    final id = (request.args['id'] ?? '').toString().trim();
    if (id.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Skill id is required.',
      );
    }
    final existing = await repo.getById(id);
    if (existing == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Skill not found: $id',
      );
    }
    await repo.delete(id);
    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: {
        'deleted': true,
        'id': id,
        'title': existing.title,
      },
    );
  }

  /// Compact summary for list/search results.
  static Map<String, dynamic> _toSummary(AgentSkill s) {
    final preview = s.content.length > 200
        ? '${s.content.substring(0, 200)}...'
        : s.content;
    return {
      'id': s.id,
      'title': s.title,
      'preview': preview,
      'enabled': s.isEnabled,
    };
  }

  /// Full representation for create/update results (verification data).
  static Map<String, dynamic> _toMap(AgentSkill s) {
    return {
      'id': s.id,
      'title': s.title,
      'content_length': s.content.length,
      'enabled': s.isEnabled,
      'assigned_agents': s.assignedAgentIds,
    };
  }
}
