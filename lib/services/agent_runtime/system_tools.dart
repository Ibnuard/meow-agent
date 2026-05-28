import '../../features/agents/data/agent_model.dart';
import '../../features/agents/data/agent_repository.dart';
import '../../features/modules/data/module_model.dart';
import '../../features/modules/data/module_repository.dart';
import '../../features/providers/data/provider_config.dart';
import '../../features/providers/data/provider_repository.dart';
import '../workspace/workspace_file_service.dart';
import 'runtime_models.dart';
import 'tool_permission_policy.dart';

/// Core Meow Agent system tools.
///
/// These tools operate on the app's own agent system and workspace markdown.
/// They are intentionally separate from the Files module: system docs define the
/// standard schema, while each agent's workspace markdown is the mutable state.
class SystemTools {
  SystemTools({
    required this.agentId,
    required this.agentName,
    required this.moduleRepository,
    this.agentRepository,
    this.providerRepository,
    this.saveAgent,
    this.deleteAgent,
    this.toolDefinitions = const [],
  });

  final String agentId;
  final String agentName;
  final ModuleRepository moduleRepository;
  final AgentRepository? agentRepository;
  final ProviderRepository? providerRepository;
  final Future<void> Function(AgentModel agent)? saveAgent;
  final Future<void> Function(String id)? deleteAgent;
  final Iterable<ToolDefinition> toolDefinitions;

  static const _coreFiles = {
    'SOUL.md',
    'MEMORY.md',
    'SKILLS.md',
    'HEARTBEAT.md',
  };

  Future<ToolExecutionResult> executeSelf() async {
    try {
      final providers = await _loadProviders();
      final agents = _loadAgents();
      final currentAgent = _findCurrentAgent(agents);
      final provider = currentAgent == null
          ? null
          : _findProviderById(providers, currentAgent.providerId);
      final wsName = _workspaceAgentName(currentAgent);
      final workspacePath = wsName.isEmpty
          ? null
          : await WorkspaceFileService.getWorkspaceDisplayPath(wsName);
      final modules = await moduleRepository.getInstalled();

      return ToolExecutionResult(
        success: true,
        toolName: 'system.self',
        data: {
          'agent': currentAgent?.toJson() ?? {'id': agentId, 'name': agentName},
          'provider': provider?.toPublicJson(),
          'workspace': {
            'path': workspacePath,
            'coreFiles': _coreFiles.toList(),
            'mutable': true,
            'note':
                'This path is the current agent workspace. Profile updates are written here, not to system standard docs.',
          },
          'counts': {
            'agents': agents.length,
            'installedModules': modules.length,
            'registeredTools': toolDefinitions.length,
          },
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.self',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeWorkspaceSchema() async {
    return const ToolExecutionResult(
      success: true,
      toolName: 'system.workspace.schema',
      data: {
        'model': {
          'systemMarkdown':
              'Global standard/base schema used to generate and understand every agent workspace. It is not the per-agent memory state.',
          'agentMarkdown':
              'Mutable markdown files inside Documents/MeowAgent/Agents/{AgentName}/. Runtime tools patch these files for the current agent.',
        },
        'files': {
          'SOUL.md': {
            'purpose':
                'Agent identity, user identity, communication style, and durable profile preferences.',
            'writePolicy':
                'Patch only the relevant field or section in the current agent workspace.',
            'examples': [
              'User says "nama saya Budi" -> update User Identity / Name.',
              'User says "panggil aku Di" -> update User Identity / Nickname.',
            ],
          },
          'MEMORY.md': {
            'purpose':
                'Persistent facts, learned preferences, bookmarks, and concise long-term context.',
            'writePolicy':
                'Append concise entries. Do not store passwords, API keys, OTPs, or secrets.',
          },
          'SKILLS.md': {
            'purpose':
                'Per-agent preferences for how to use available tools. The real runtime tool registry is system-managed.',
            'writePolicy': 'Patch tool-use preferences or constraints only.',
          },
          'HEARTBEAT.md': {
            'purpose':
                'Runtime status snapshot: current task, state, last tool, last result, and last error.',
            'writePolicy': 'Runtime-managed. Do not store user profile here.',
          },
        },
      },
    );
  }

  Future<ToolExecutionResult> executeWorkspaceRead(
    Map<String, dynamic> args,
  ) async {
    try {
      final wsName = _workspaceAgentName(_findCurrentAgent(_loadAgents()));
      if (wsName.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.workspace.read',
          error: 'Current agent workspace is not available.',
        );
      }

      final filename = _normalizeCoreFilename(args['file'] ?? args['filename']);
      if (filename == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'system.workspace.read',
          error: 'file must be one of: ${_coreFiles.join(', ')}.',
        );
      }

      final content = await WorkspaceFileService.readFile(wsName, filename);
      final section = (args['section'] as String? ?? '').trim();
      final sectionContent = section.isEmpty
          ? null
          : _extractMarkdownSection(content, section);

      return ToolExecutionResult(
        success: true,
        toolName: 'system.workspace.read',
        data: {
          'agentName': wsName,
          'file': filename,
          'section': section.isEmpty ? null : section,
          'content': sectionContent ?? content,
          'sectionFound': section.isEmpty ? null : sectionContent != null,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.workspace.read',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeProfileUpdate(
    Map<String, dynamic> args,
  ) async {
    try {
      final wsName = _workspaceAgentName(_findCurrentAgent(_loadAgents()));
      if (wsName.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.profile.update',
          error: 'Current agent workspace is not available.',
        );
      }

      final field = (args['field'] as String? ?? '').trim();
      final value = (args['value'] as String? ?? '').trim();
      if (field.isEmpty || value.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.profile.update',
          error: 'field and value are required.',
        );
      }
      if (_looksSensitive(value)) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.profile.update',
          error:
              'Refusing to store secrets such as passwords, API keys, tokens, or OTPs in SOUL.md.',
        );
      }

      final label = _profileFieldLabel(field);
      if (label == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'system.profile.update',
          error:
              'Unsupported profile field "$field". Use name, nickname, preferred_language, timezone, work_role, main_project, communication_style, or design_preference.',
        );
      }

      final oldContent = await WorkspaceFileService.readFile(wsName, 'SOUL.md');
      final content = oldContent.trim().isEmpty
          ? _minimalSoul(wsName)
          : oldContent;
      final updated = _upsertFieldInSection(
        content: content,
        sectionTitle: 'User Identity',
        label: label,
        value: value,
      );
      await WorkspaceFileService.writeFile(wsName, 'SOUL.md', updated);

      return ToolExecutionResult(
        success: true,
        toolName: 'system.profile.update',
        data: {
          'agentName': wsName,
          'file': 'SOUL.md',
          'section': 'User Identity',
          'field': label,
          'value': value,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.profile.update',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeMemoryAppend(
    Map<String, dynamic> args,
  ) async {
    try {
      final wsName = _workspaceAgentName(_findCurrentAgent(_loadAgents()));
      if (wsName.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.memory.append',
          error: 'Current agent workspace is not available.',
        );
      }

      final value =
          (args['content'] as String? ??
                  args['value'] as String? ??
                  args['fact'] as String? ??
                  '')
              .trim();
      if (value.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.memory.append',
          error: 'content is required.',
        );
      }
      if (_looksSensitive(value)) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.memory.append',
          error:
              'Refusing to store secrets such as passwords, API keys, tokens, or OTPs in MEMORY.md.',
        );
      }

      final category = (args['category'] as String? ?? 'fact').trim();
      final section = _memorySectionFor(category);
      final oldContent = await WorkspaceFileService.readFile(
        wsName,
        'MEMORY.md',
      );
      final content = oldContent.trim().isEmpty
          ? _minimalMemory(wsName)
          : oldContent;
      final date = DateTime.now().toIso8601String().split('T').first;
      final entry = '- $date: $value';
      final updated = _appendBulletToSection(
        content: content,
        sectionTitle: section,
        entry: entry,
      );
      await WorkspaceFileService.writeFile(wsName, 'MEMORY.md', updated);

      return ToolExecutionResult(
        success: true,
        toolName: 'system.memory.append',
        data: {
          'agentName': wsName,
          'file': 'MEMORY.md',
          'section': section,
          'entry': entry,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.memory.append',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeAgentsList() async {
    try {
      final agents = _loadAgents();
      final providers = await _loadProviders();
      final result = <Map<String, dynamic>>[];
      for (final agent in agents) {
        final provider = _findProviderById(providers, agent.providerId);
        result.add({
          ...agent.toJson(),
          'provider': provider?.toPublicJson(),
          'isCurrent': agent.id == agentId,
          'workspacePath': await WorkspaceFileService.getWorkspaceDisplayPath(
            agent.name,
          ),
        });
      }

      return ToolExecutionResult(
        success: true,
        toolName: 'system.agents.list',
        data: {'count': result.length, 'agents': result},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.agents.list',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeAgentsCreate(
    Map<String, dynamic> args,
  ) async {
    try {
      final repo = agentRepository;
      if (repo == null && saveAgent == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.agents.create',
          error: 'Agent repository is not available.',
        );
      }

      final name = (args['name'] as String? ?? '').trim();
      if (name.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.agents.create',
          error: 'name is required.',
        );
      }

      final agents = _loadAgents();
      final duplicate = agents.any(
        (a) => a.name.toLowerCase() == name.toLowerCase(),
      );
      if (duplicate) {
        return ToolExecutionResult(
          success: false,
          toolName: 'system.agents.create',
          error: 'Agent "$name" already exists.',
        );
      }

      final providers = await _loadProviders();
      final provider = _resolveProvider(providers, args);
      if (provider == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'system.agents.create',
          data: {
            'providers': providers.map((p) => p.toPublicJson()).toList(),
            'count': providers.length,
          },
          error: providers.isEmpty
              ? 'No provider is configured. Create a provider first.'
              : 'providerId is required because multiple providers are available.',
        );
      }

      final maxContextLength =
          (args['maxContextLength'] as num?)?.toInt() ?? 8191;
      final agent = AgentModel(
        name: name,
        providerId: provider.id,
        maxContextLength: maxContextLength.clamp(512, 1000000).toInt(),
        iconKey: args['iconKey'] as String?,
        colorKey: args['colorKey'] as String?,
      );

      final save = saveAgent;
      if (save != null) {
        await save(agent);
      } else {
        await repo!.save(agent);
      }

      // Bake personality into the new agent's SOUL.md if requested.
      // Doing it here avoids the cross-agent boundary issue —
      // system.profile.update would only touch the *current* chat agent.
      final role = (args['role'] as String? ?? '').trim();
      final persona =
          (args['persona'] as String? ?? args['description'] as String? ?? '')
              .trim();
      final communicationStyle =
          (args['communicationStyle'] as String? ??
                  args['style'] as String? ??
                  '')
              .trim();
      String? personaApplied;
      if (role.isNotEmpty ||
          persona.isNotEmpty ||
          communicationStyle.isNotEmpty) {
        final soul = _buildPersonaSoul(
          name: name,
          role: role,
          persona: persona,
          communicationStyle: communicationStyle,
        );
        await WorkspaceFileService.writeFile(name, 'SOUL.md', soul);
        personaApplied = [
          if (role.isNotEmpty) 'role',
          if (persona.isNotEmpty) 'persona',
          if (communicationStyle.isNotEmpty) 'communicationStyle',
        ].join(', ');
      }

      return ToolExecutionResult(
        success: true,
        toolName: 'system.agents.create',
        data: {
          'agent': agent.toJson(),
          'provider': provider.toPublicJson(),
          'workspacePath': await WorkspaceFileService.getWorkspaceDisplayPath(
            agent.name,
          ),
          'createdFrom': 'system markdown standard template',
          'personaApplied': ?personaApplied,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.agents.create',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeAgentsDelete(
    Map<String, dynamic> args,
  ) async {
    try {
      final repo = agentRepository;
      if (repo == null && deleteAgent == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.agents.delete',
          error: 'Agent repository is not available.',
        );
      }

      final agents = _loadAgents();
      final id = (args['id'] as String? ?? args['agentId'] as String? ?? '')
          .trim();
      final name = (args['name'] as String? ?? '').trim();
      final target = _findAgent(agents, id: id, name: name);
      if (target == null) {
        // Provide the live agent list so the reviewer can replan with a
        // fallback `name` lookup. Stale ids occur naturally in multi-step
        // tasks because the planner's snapshot is captured BEFORE earlier
        // mutating subgoals have run.
        final available = agents
            .where((a) => a.id != agentId)
            .map((a) => {'id': a.id, 'name': a.name})
            .toList();
        return ToolExecutionResult(
          success: false,
          toolName: 'system.agents.delete',
          error:
              'Target agent not found by id="$id" or name="$name". Retry with one of the names listed in `data.available`.',
          data: {
            'available': available,
            'tried': {'id': id, 'name': name},
            'hint':
                'Names are case-insensitive. Prefer name when calling this tool inside a multi-step task.',
          },
        );
      }
      if (target.id == agentId) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.agents.delete',
          error:
              'Refusing to delete the current active agent from inside its own chat.',
        );
      }

      final delete = deleteAgent;
      if (delete != null) {
        await delete(target.id);
      } else {
        await repo!.delete(target.id);
      }

      return ToolExecutionResult(
        success: true,
        toolName: 'system.agents.delete',
        data: {'deleted': true, 'agent': target.toJson()},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.agents.delete',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeProvidersList() async {
    try {
      final providers = await _loadProviders();
      return ToolExecutionResult(
        success: true,
        toolName: 'system.providers.list',
        data: {
          'count': providers.length,
          'providers': providers.map((p) => p.toPublicJson()).toList(),
          'apiKeysIncluded': false,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.providers.list',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeModulesList() async {
    try {
      final installed = await moduleRepository.getInstalled();
      final installedById = {for (final module in installed) module.id: module};
      final available = ModuleRegistry.available.map((spec) {
        final installedModule = installedById[spec.id];
        return {
          'id': spec.id,
          'name': spec.name,
          'description': spec.description,
          'installed': installedModule != null,
          'enabled': installedModule?.enabled ?? false,
          'settings': installedModule?.settings ?? spec.settings,
        };
      }).toList();

      return ToolExecutionResult(
        success: true,
        toolName: 'system.modules.list',
        data: {
          'availableCount': ModuleRegistry.available.length,
          'installedCount': installed.length,
          'enabledCount': installed.where((m) => m.enabled).length,
          'modules': available,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.modules.list',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeToolsList() async {
    try {
      final policy = ToolPermissionPolicy(moduleRepository);
      final tools = <Map<String, dynamic>>[];
      for (final def in toolDefinitions) {
        final check = await policy.check(def.name);
        tools.add({
          'name': def.name,
          'description': def.description,
          'risk': def.risk,
          'requiresConfirmation': def.requiresConfirmation,
          'inputSchema': def.inputSchema,
          'available': check.allowed,
          'moduleId': check.requirement?.moduleId,
          'blockedReason': check.reason?.name,
          'blockedSetting': check.requirement?.settingKey,
        });
      }

      return ToolExecutionResult(
        success: true,
        toolName: 'system.tools.list',
        data: {
          'count': tools.length,
          'availableCount': tools.where((t) => t['available'] == true).length,
          'tools': tools,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.tools.list',
        error: e.toString(),
      );
    }
  }

  List<AgentModel> _loadAgents() {
    final repo = agentRepository;
    if (repo == null) return const [];
    return repo.loadAll();
  }

  Future<List<ProviderConfig>> _loadProviders() async {
    final repo = providerRepository;
    if (repo == null) return const [];
    return repo.loadAll();
  }

  AgentModel? _findCurrentAgent(List<AgentModel> agents) {
    for (final agent in agents) {
      if (agent.id == agentId) return agent;
    }
    for (final agent in agents) {
      if (agent.name == agentName) return agent;
    }
    return null;
  }

  String _workspaceAgentName(AgentModel? currentAgent) {
    if (currentAgent != null) return currentAgent.name;
    return agentName;
  }

  ProviderConfig? _findProviderById(List<ProviderConfig> providers, String id) {
    for (final provider in providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  ProviderConfig? _resolveProvider(
    List<ProviderConfig> providers,
    Map<String, dynamic> args,
  ) {
    if (providers.isEmpty) return null;
    final providerId = (args['providerId'] as String? ?? '').trim();
    if (providerId.isNotEmpty) {
      for (final provider in providers) {
        if (provider.id == providerId) return provider;
      }
      return null;
    }

    final query =
        (args['provider'] as String? ??
                args['providerName'] as String? ??
                args['providerNickname'] as String? ??
                '')
            .trim()
            .toLowerCase();
    if (query.isNotEmpty) {
      for (final provider in providers) {
        if (provider.nickname.toLowerCase() == query ||
            provider.model.toLowerCase() == query) {
          return provider;
        }
      }
    }

    return providers.length == 1 ? providers.first : null;
  }

  AgentModel? _findAgent(
    List<AgentModel> agents, {
    String id = '',
    String name = '',
  }) {
    for (final agent in agents) {
      if (id.isNotEmpty && agent.id == id) return agent;
      if (name.isNotEmpty && agent.name.toLowerCase() == name.toLowerCase()) {
        return agent;
      }
    }
    return null;
  }

  String? _normalizeCoreFilename(Object? value) {
    final raw = (value as String? ?? '').trim();
    if (raw.isEmpty) return null;
    final upper = raw.toUpperCase();
    for (final file in _coreFiles) {
      if (file.toUpperCase() == upper) return file;
    }
    return null;
  }

  String? _profileFieldLabel(String field) {
    final key = field.toLowerCase().replaceAll('-', '_').replaceAll(' ', '_');
    return switch (key) {
      'name' || 'user_name' || 'nama' => 'Name',
      'nickname' || 'nick' || 'panggilan' => 'Nickname',
      'preferred_language' || 'language' || 'bahasa' => 'Preferred Language',
      'timezone' || 'time_zone' || 'zona_waktu' => 'Timezone',
      'work_role' || 'role' || 'job' || 'pekerjaan' => 'Work/Role',
      'main_project' || 'project' || 'proyek' => 'Main Projects',
      'communication_style' ||
      'style' ||
      'gaya_komunikasi' => 'Communication Style',
      'design_preference' ||
      'formatting' ||
      'response_style' => 'Design Preference',
      _ => null,
    };
  }

  String _memorySectionFor(String category) {
    final key = category
        .toLowerCase()
        .replaceAll('-', '_')
        .replaceAll(' ', '_');
    return switch (key) {
      'preference' ||
      'preferences' ||
      'learned_preference' => 'Learned Preferences',
      'bookmark' || 'bookmarks' => 'Bookmarks',
      'session' || 'session_note' || 'session_notes' => 'Session Notes',
      _ => 'Facts',
    };
  }

  String _upsertFieldInSection({
    required String content,
    required String sectionTitle,
    required String label,
    required String value,
  }) {
    final lines = content.split('\n');
    var sectionStart = _findHeading(lines, sectionTitle);
    if (sectionStart == -1) {
      final separator = content.endsWith('\n') ? '' : '\n';
      return '$content$separator\n## $sectionTitle\n\n$label: $value\n';
    }

    final sectionEnd = _findSectionEnd(lines, sectionStart + 1);
    final labelRegex = RegExp(
      '^\\s*${RegExp.escape(label)}\\s*:',
      caseSensitive: false,
    );
    for (var i = sectionStart + 1; i < sectionEnd; i++) {
      if (labelRegex.hasMatch(lines[i])) {
        lines[i] = '$label: $value';
        return _joinMarkdownLines(lines);
      }
    }

    var insertAt = sectionEnd;
    while (insertAt > sectionStart + 1 && lines[insertAt - 1].trim().isEmpty) {
      insertAt--;
    }
    lines.insert(insertAt, '$label: $value');
    return _joinMarkdownLines(lines);
  }

  String _appendBulletToSection({
    required String content,
    required String sectionTitle,
    required String entry,
  }) {
    final lines = content.split('\n');
    final normalizedEntry = entry.toLowerCase();
    for (final line in lines) {
      if (line.trim().toLowerCase() == normalizedEntry) {
        return content;
      }
    }

    var sectionStart = _findHeading(lines, sectionTitle);
    if (sectionStart == -1) {
      final separator = content.endsWith('\n') ? '' : '\n';
      return '$content$separator\n## $sectionTitle\n\n$entry\n';
    }

    final sectionEnd = _findSectionEnd(lines, sectionStart + 1);
    var insertAt = sectionEnd;
    while (insertAt > sectionStart + 1 && lines[insertAt - 1].trim().isEmpty) {
      insertAt--;
    }
    lines.insert(insertAt, entry);
    return _joinMarkdownLines(lines);
  }

  int _findHeading(List<String> lines, String title) {
    final needle = title.trim().toLowerCase();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('##')) continue;
      final text = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
      if (text.toLowerCase() == needle) return i;
    }
    return -1;
  }

  int _findSectionEnd(List<String> lines, int start) {
    for (var i = start; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('## ') || line == '---') {
        return i;
      }
    }
    return lines.length;
  }

  String? _extractMarkdownSection(String content, String sectionTitle) {
    final lines = content.split('\n');
    final start = _findHeading(lines, sectionTitle);
    if (start == -1) return null;
    final end = _findSectionEnd(lines, start + 1);
    return lines.sublist(start, end).join('\n').trim();
  }

  String _joinMarkdownLines(List<String> lines) {
    final joined = lines.join('\n');
    return joined.endsWith('\n') ? joined : '$joined\n';
  }

  bool _looksSensitive(String value) {
    final text = value.toLowerCase();
    return RegExp(
      r'\b(password|passwd|api key|apikey|token|secret|otp|one time password|private key|bearer)\b',
    ).hasMatch(text);
  }

  String _minimalSoul(String name) =>
      '''# SOUL.md

## Agent Identity

Name: $name
Role: Android-native personal agentic AI assistant.

---

## User Identity

Name: [Your Name]
Nickname: [Optional Nickname]
Preferred Language: [Not set]
Timezone: [Your Timezone]
''';

  /// Build a SOUL.md that bakes in the requested persona/role on creation.
  /// Used when system.agents.create is called with persona/role/style args.
  String _buildPersonaSoul({
    required String name,
    required String role,
    required String persona,
    required String communicationStyle,
  }) {
    final buf = StringBuffer()
      ..writeln('# SOUL.md')
      ..writeln()
      ..writeln('## Agent Identity')
      ..writeln()
      ..writeln('Name: $name');
    if (role.isNotEmpty) {
      buf.writeln('Role: $role');
    } else {
      buf.writeln('Role: Android-native personal agentic AI assistant.');
    }
    if (persona.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('### Persona')
        ..writeln()
        ..writeln(persona);
    }
    if (communicationStyle.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('### Communication Style')
        ..writeln()
        ..writeln(communicationStyle);
    }
    buf
      ..writeln()
      ..writeln('---')
      ..writeln()
      ..writeln('## User Identity')
      ..writeln()
      ..writeln('Name: [Your Name]')
      ..writeln('Nickname: [Optional Nickname]')
      ..writeln('Preferred Language: [Not set]')
      ..writeln('Timezone: [Your Timezone]');
    return buf.toString();
  }

  String _minimalMemory(String name) => '''# MEMORY.md - $name

## Overview

This file stores persistent memory and context that carries across sessions.

---

## Facts

---

## Session Notes

---

## Learned Preferences

---

## Bookmarks

''';
}
