import 'package:flutter/services.dart';

import '../../core/storage/meow_config_repository.dart';
import '../permission/permission_manager.dart';
import '../../features/agents/data/agent_model.dart';
import '../../features/agents/data/agent_repository.dart';
import '../../features/modules/data/module_model.dart';
import '../../features/modules/data/module_repository.dart';
import '../../features/providers/data/provider_config.dart';
import '../../features/providers/data/provider_repository.dart';
import '../workspace/workspace_file_service.dart';
import 'runtime_models.dart';
import 'tool_permission_policy.dart';

part 'system_tools_workspace.dart';
part 'system_tools_introspection.dart';
part 'system_tools_export.dart';
part 'system_tools_config.dart';

/// Core Meow Agent system tools.
///
/// These tools operate on the app's own agent system and workspace markdown.
/// They are intentionally separate from the Files module: system docs define the
/// standard schema, while each agent's workspace markdown is the mutable state.
///
/// The execute methods are split by domain into part files:
/// - [system_tools_agent.dart]         — agent CRUD
/// - [system_tools_workspace.dart]     — self, workspace, profile, memory
/// - [system_tools_introspection.dart] — provider, module, tool listing & toggle
/// - [system_tools_export.dart]        — export/import
class SystemTools {
  SystemTools({
    required this.agentId,
    required this.agentName,
    required this.moduleRepository,
    this.configRepository,
    this.agentRepository,
    this.providerRepository,
    this.saveAgent,
    this.deleteAgent,
    this.toolDefinitions = const [],
  });

  final String agentId;
  final String agentName;
  final ModuleRepository moduleRepository;
  final MeowConfigRepository? configRepository;
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

  // ─── Shared helpers (used by part-file extensions) ─────────────────────────

  List<AgentModel> loadAgents() {
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

  ProviderConfig? resolveProvider(
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
            provider.models.any((model) => model.toLowerCase() == query)) {
          return provider;
        }
      }
      return null;
    }

    final currentAgent = findCurrentAgent(loadAgents());
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

  String? normalizeCoreFilename(Object? value) {
    final raw = (value as String? ?? '').trim();
    if (raw.isEmpty) return null;
    final upper = raw.toUpperCase();
    for (final file in _coreFiles) {
      if (file.toUpperCase() == upper) return file;
    }
    return null;
  }

  String? profileFieldLabel(String field) {
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

  String memorySectionFor(String category) {
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

  String upsertFieldInSection({
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

  String appendBulletToSection({
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

  String minimalSoul(String name) =>
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
  String buildPersonaSoul({
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

  String minimalMemory(String name) => '''# MEMORY.md - $name

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

  String _joinMarkdownLines(List<String> lines) {
    final joined = lines.join('\n');
    return joined.endsWith('\n') ? joined : '$joined\n';
  }
}
