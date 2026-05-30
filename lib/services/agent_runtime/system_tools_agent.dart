part of 'system_tools.dart';

/// Agent CRUD execute methods extracted from [SystemTools].
extension SystemToolsAgent on SystemTools {
  // ─── system.agents.list ────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeAgentsList() async {
    try {
      final agents = loadAgents();
      final providers = await loadProviders();
      final result = <Map<String, dynamic>>[];
      for (final agent in agents) {
        final provider = findProviderById(providers, agent.providerId);
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

  // ─── system.agents.create ──────────────────────────────────────────────────

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

      final agents = loadAgents();
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

      final providers = await loadProviders();
      final provider = resolveProvider(providers, args);
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
        final soul = buildPersonaSoul(
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
          'personaApplied': personaApplied,
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

  // ─── system.agents.delete ──────────────────────────────────────────────────

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

      final agents = loadAgents();
      final id = (args['id'] as String? ?? args['agentId'] as String? ?? '')
          .trim();
      final name = (args['name'] as String? ?? '').trim();
      final target = findAgent(agents, id: id, name: name);
      if (target == null) {
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

  // ─── system.agents.update ──────────────────────────────────────────────────

  Future<ToolExecutionResult> executeAgentsUpdate(
    Map<String, dynamic> args,
  ) async {
    try {
      final repo = agentRepository;
      final save = saveAgent;
      if (repo == null && save == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.agents.update',
          error: 'Agent repository is not available.',
        );
      }
      final agents = loadAgents();
      final id = (args['id'] as String? ?? args['agentId'] as String? ?? '')
          .trim();
      final lookupName = (args['name'] as String? ?? '').trim();
      final target = findAgent(agents, id: id, name: lookupName);
      if (target == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'system.agents.update',
          error: 'Agent not found by id="$id" or name="$lookupName".',
          data: {
            'available': agents
                .map((a) => {'id': a.id, 'name': a.name})
                .toList(),
          },
        );
      }

      final newName = (args['newName'] as String? ?? '').trim();
      final newProviderRaw = (args['providerId'] as String? ?? '').trim();
      final newMaxContext = (args['maxContextLength'] as num?)?.toInt();
      final newIcon = args['iconKey'] as String?;
      final newColor = args['colorKey'] as String?;

      String? finalProviderId;
      if (newProviderRaw.isNotEmpty) {
        final providers = await loadProviders();
        final found = providers
            .where(
              (p) =>
                  p.id == newProviderRaw ||
                  p.nickname.toLowerCase() == newProviderRaw.toLowerCase(),
            )
            .firstOrNull;
        if (found == null) {
          return ToolExecutionResult(
            success: false,
            toolName: 'system.agents.update',
            error: 'Provider not found: $newProviderRaw',
          );
        }
        finalProviderId = found.id;
      }

      final updated = target.copyWith(
        name: newName.isEmpty ? null : newName,
        providerId: finalProviderId,
        maxContextLength: newMaxContext?.clamp(512, 1000000).toInt(),
        iconKey: newIcon,
        colorKey: newColor,
      );

      if (save != null) {
        await save(updated);
      } else {
        await repo!.save(updated);
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'system.agents.update',
        data: {
          'agent': updated.toJson(),
          'changedFields': [
            if (newName.isNotEmpty) 'name',
            if (finalProviderId != null) 'providerId',
            if (newMaxContext != null) 'maxContextLength',
            if (newIcon != null) 'iconKey',
            if (newColor != null) 'colorKey',
          ],
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.agents.update',
        error: e.toString(),
      );
    }
  }
}