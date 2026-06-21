import 'package:flutter/services.dart';

import '../../core/storage/agent_memory_repository.dart';
import '../../core/storage/agent_soul_repository.dart';
import '../../core/storage/app_settings_repository.dart';
import '../../core/storage/module_entry_repository.dart';
import '../permission/permission_manager.dart';
import '../../features/agents/data/agent_model.dart';
import '../../features/agents/data/agent_repository.dart';
import '../../features/modules/data/module_model.dart';
import '../../features/modules/data/module_repository.dart';
import '../../features/providers/data/provider_config.dart';
import '../../features/providers/data/provider_repository.dart';
import '../workspace/workspace_file_service.dart';
import 'module_plugin.dart';
import 'runtime_models.dart';
import 'tool_permission_policy.dart';

part 'system_tools_workspace.dart';
part 'system_tools_introspection.dart';
part 'system_tools_export.dart';
part 'system_tools_config.dart';

/// Core Meow Agent system tools.
///
/// These tools operate on the app's own agent system. Identity (`agent_soul`)
/// and long-term memory (`agent_memory`) live in the local SQLite database;
/// the workspace folder holds user-uploaded files only.
///
/// The execute methods are split by domain into part files:
/// - [system_tools_workspace.dart]     — self, workspace, profile, memory
/// - [system_tools_introspection.dart] — provider, module, tool listing & toggle
/// - [system_tools_export.dart]        — export/import
/// - [system_tools_config.dart]        — config read/patch
class SystemTools {
  SystemTools({
    required this.agentId,
    required this.agentName,
    required this.moduleRepository,
    this.appSettings,
    this.moduleEntries,
    this.agentRepository,
    this.providerRepository,
    this.saveAgent,
    this.deleteAgent,
    this.toolDefinitions = const [],
    this.coreSoulRepo,
    this.coreMemoryRepo,
  });

  final String agentId;
  final String agentName;
  final ModuleRepository moduleRepository;
  final AppSettingsRepository? appSettings;
  final ModuleEntryRepository? moduleEntries;
  final AgentRepository? agentRepository;
  final ProviderRepository? providerRepository;
  final Future<void> Function(AgentModel agent)? saveAgent;
  final Future<void> Function(String id)? deleteAgent;
  final Iterable<ToolDefinition> toolDefinitions;
  final AgentSoulRepository? coreSoulRepo;
  final AgentMemoryRepository? coreMemoryRepo;

  // ─── Shared helpers (used by part-file extensions) ─────────────────────────

  Future<List<AgentModel>> loadAgents() async {
    final repo = agentRepository;
    if (repo == null) return const [];
    return repo.loadAll();
  }

  Future<List<ProviderConfig>> loadProviders() async {
    final repo = providerRepository;
    if (repo == null) return const [];
    return repo.loadAll();
  }

  AgentModel? findCurrentAgent(List<AgentModel> agents) {
    for (final agent in agents) {
      if (agent.id == agentId) return agent;
    }
    for (final agent in agents) {
      if (agent.name == agentName) return agent;
    }
    return null;
  }

  String workspaceAgentName(AgentModel? currentAgent) {
    if (currentAgent != null) return currentAgent.name;
    return agentName;
  }

  ProviderConfig? findProviderById(List<ProviderConfig> providers, String id) {
    for (final provider in providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  Future<ProviderConfig?> resolveProvider(
    List<ProviderConfig> providers,
    Map<String, dynamic> args,
  ) async {
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
            provider.models.any((model) => model.toLowerCase() == query)) {
          return provider;
        }
      }
      return null;
    }

    final currentAgent = findCurrentAgent(await loadAgents());
    final currentProviderId = currentAgent?.providerId ?? '';
    if (currentProviderId.isNotEmpty) {
      final currentProvider = findProviderById(providers, currentProviderId);
      if (currentProvider != null) return currentProvider;
    }

    return providers.length == 1 ? providers.first : null;
  }

  AgentModel? findAgent(
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

  String? extractMarkdownSection(String content, String sectionTitle) {
    final lines = content.split('\n');
    final start = _findHeading(lines, sectionTitle);
    if (start == -1) return null;
    final end = _findSectionEnd(lines, start + 1);
    return lines.sublist(start, end).join('\n').trim();
  }

  bool looksSensitive(String value) {
    final text = value.toLowerCase();
    return RegExp(
      r'\b(password|passwd|api key|apikey|token|secret|otp|one time password|private key|bearer)\b',
    ).hasMatch(text);
  }

  // ─── Private markdown helpers ───────────────────────────────────────────────

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
}
