part of 'system_tools.dart';

/// Workspace & profile execute methods extracted from [SystemTools].
extension SystemToolsWorkspace on SystemTools {
  static const _rtbChannel = MethodChannel('com.meowagent/app_control');
  static const _selfPackage = 'com.meowagent.meow_agent';

  // ─── system.rtb ─────────────────────────────────────────────────────────────

  /// Return to base: bring the user back to Meow Agent from any external app.
  Future<ToolExecutionResult> executeReturnToBase() async {
    try {
      final success = await _rtbChannel.invokeMethod<bool>(
            'openApp',
            {'package': _selfPackage},
          ) ??
          false;
      return ToolExecutionResult(
        success: success,
        toolName: 'system.rtb',
        data: {'package': _selfPackage, 'returned': success},
        error: success ? null : 'Could not return to Meow Agent.',
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.rtb',
        error: e.toString(),
      );
    }
  }

  // ─── system.self ───────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeSelf() async {
    try {
      final providers = await loadProviders();
      final agents = await loadAgents();
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
            'mutable': true,
            'note':
                'This path holds user files only (uploads, exports, PDFs). Identity and memory live in the local database, not here.',
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
        'architecture': {
          'identity':
              'User profile (name, nickname, timezone, preferences) is stored in a local SQLite database. Use system.profile.update to modify.',
          'memory':
              'Long-term memory (facts, preferences, bookmarks) is stored in a local SQLite database. Use system.memory.append to add entries.',
          'workspace':
              'The folder Documents/MeowAgent/Agents/{AgentName}/ is for USER FILES only — documents, PDFs, exports. It is NOT used for identity or memory.',
        },
        'tools': {
          'system.profile.update': {
            'purpose': 'Update a user identity field in the database.',
            'fields': AgentSoulRepository.profileFields,
            'examples': [
              'User says "my name is Budi" -> system.profile.update(field: "name", value: "Budi")',
              'User says "call me Di" -> system.profile.update(field: "nickname", value: "Di")',
            ],
          },
          'system.memory.append': {
            'purpose':
                'Append a persistent memory entry to the database.',
            'categories': AgentSoulRepository.memoryCategories,
            'policy':
                'Append concise entries. Do not store passwords, API keys, OTPs, or secrets.',
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
      final wsName = workspaceAgentName(findCurrentAgent(await loadAgents()));
      if (wsName.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.workspace.read',
          error: 'Current agent workspace is not available.',
        );
      }

      final filename = (args['file'] as String? ?? args['filename'] as String? ?? '').trim();
      if (filename.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.workspace.read',
          error: 'file is required (relative path inside the agent workspace).',
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

  // ─── system.profile.update ───────────────────────────────
  //
  // Phase 7: writes go to the `agent_soul` SQLite table, NOT to SOUL.md.
  // No filesystem permission required, atomic, reactive (UI subscribers see
  // the new value immediately).

  Future<ToolExecutionResult> executeProfileUpdate(
    Map<String, dynamic> args,
  ) async {
    try {
      final repo = coreSoulRepo;
      if (repo == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.profile.update',
          error: 'Profile store is not available.',
        );
      }
      if (agentId.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.profile.update',
          error: 'No active agent.',
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
              'Refusing to store secrets such as passwords, API keys, tokens, or OTPs in the profile.',
        );
      }

      final allowed = AgentSoulRepository.profileFields.toSet();
      if (!allowed.contains(field)) {
        return ToolExecutionResult(
          success: false,
          toolName: 'system.profile.update',
          error:
              'Unsupported profile field "$field". Use ${allowed.join(', ')}.',
        );
      }

      final updated = await repo.updateField(
        agentId: agentId,
        field: field,
        value: value,
      );

      return ToolExecutionResult(
        success: true,
        toolName: 'system.profile.update',
        data: {
          'agentId': agentId,
          'agentName': agentName,
          'field': field,
          'value': value,
          'updatedAt': updated.updatedAt.toIso8601String(),
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

  // ─── system.memory.append ────────────────────────────────
  //
  // Phase 7: writes append a row to the `agent_memory` SQLite table, NOT to
  // MEMORY.md. The repo persists category, content, and timestamp; recall is
  // a single indexed query.

  Future<ToolExecutionResult> executeMemoryAppend(
    Map<String, dynamic> args,
  ) async {
    try {
      final repo = coreMemoryRepo;
      if (repo == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.memory.append',
          error: 'Memory store is not available.',
        );
      }
      if (agentId.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.memory.append',
          error: 'No active agent.',
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
              'Refusing to store secrets such as passwords, API keys, tokens, or OTPs in memory.',
        );
      }

      final rawCategory = (args['category'] as String? ?? 'fact').trim();
      final allowedCategories = AgentSoulRepository.memoryCategories.toSet();
      final category = allowedCategories.contains(rawCategory)
          ? rawCategory
          : 'fact';

      final entry = await repo.append(
        agentId: agentId,
        content: value,
        category: category,
      );

      return ToolExecutionResult(
        success: true,
        toolName: 'system.memory.append',
        data: {
          'agentId': agentId,
          'agentName': agentName,
          'memoryId': entry.id,
          'category': entry.category,
          'content': entry.content,
          'createdAt': entry.createdAt.toIso8601String(),
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