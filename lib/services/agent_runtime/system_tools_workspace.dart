part of 'system_tools.dart';

/// Workspace & profile execute methods extracted from [SystemTools].
extension SystemToolsWorkspace on SystemTools {
  // ─── system.self ───────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeSelf() async {
    try {
      final providers = await loadProviders();
      final agents = loadAgents();
      final currentAgent = findCurrentAgent(agents);
      final provider = currentAgent == null
          ? null
          : findProviderById(providers, currentAgent.providerId);
      final wsName = workspaceAgentName(currentAgent);
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
            'coreFiles': SystemTools._coreFiles.toList(),
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

  // ─── system.workspace.schema ───────────────────────────────────────────────

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

  // ─── system.workspace.read ─────────────────────────────────────────────────

  Future<ToolExecutionResult> executeWorkspaceRead(
    Map<String, dynamic> args,
  ) async {
    try {
      final wsName = workspaceAgentName(findCurrentAgent(loadAgents()));
      if (wsName.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.workspace.read',
          error: 'Current agent workspace is not available.',
        );
      }

      final filename = normalizeCoreFilename(args['file'] ?? args['filename']);
      if (filename == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'system.workspace.read',
          error: 'file must be one of: ${SystemTools._coreFiles.join(', ')}.',
        );
      }

      final content = await WorkspaceFileService.readFile(wsName, filename);
      final section = (args['section'] as String? ?? '').trim();
      final sectionContent = section.isEmpty
          ? null
          : extractMarkdownSection(content, section);

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

  // ─── system.profile.update ─────────────────────────────────────────────────

  Future<ToolExecutionResult> executeProfileUpdate(
    Map<String, dynamic> args,
  ) async {
    try {
      final wsName = workspaceAgentName(findCurrentAgent(loadAgents()));
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
      if (looksSensitive(value)) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.profile.update',
          error:
              'Refusing to store secrets such as passwords, API keys, tokens, or OTPs in SOUL.md.',
        );
      }

      final label = profileFieldLabel(field);
      if (label == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'system.profile.update',
          error:
              'Unsupported profile field "$field". Use name, nickname, preferred_language, timezone, work_role, main_project, communication_style, or design_preference.',
        );
      }

      final oldContent = await WorkspaceFileService.readFile(
        wsName,
        'SOUL.md',
      );
      final content = oldContent.trim().isEmpty
          ? minimalSoul(wsName)
          : oldContent;
      final updated = upsertFieldInSection(
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

  // ─── system.memory.append ──────────────────────────────────────────────────

  Future<ToolExecutionResult> executeMemoryAppend(
    Map<String, dynamic> args,
  ) async {
    try {
      final wsName = workspaceAgentName(findCurrentAgent(loadAgents()));
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
      if (looksSensitive(value)) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.memory.append',
          error:
              'Refusing to store secrets such as passwords, API keys, tokens, or OTPs in MEMORY.md.',
        );
      }

      final category = (args['category'] as String? ?? 'fact').trim();
      final section = memorySectionFor(category);
      final oldContent = await WorkspaceFileService.readFile(
        wsName,
        'MEMORY.md',
      );
      final content = oldContent.trim().isEmpty
          ? minimalMemory(wsName)
          : oldContent;
      final date = DateTime.now().toIso8601String().split('T').first;
      final entry = '- $date: $value';
      final updated = appendBulletToSection(
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
}