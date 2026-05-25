import 'dart:io';

import '../workspace/workspace_file_service.dart';
import '../workspace/workspace_paths.dart';
import 'runtime_models.dart';

/// Loads and manages agent workspace files from external Documents storage.
///
/// Reads from: /Documents/MeowAgent/Agents/{AgentName}/
///   - SOUL.md
///   - MEMORY.md
///   - SKILLS.md
///   - HEARTBEAT.md
///
/// Files are re-read on every runtime session start (no aggressive caching)
/// to support external edits from file managers.
class WorkspaceLoader {
  /// Load workspace for a given agent by name.
  Future<AgentWorkspace> load(String agentName) async {
    return AgentWorkspace(
      soul: await WorkspaceFileService.readFile(agentName, 'SOUL.md'),
      memory: await WorkspaceFileService.readFile(agentName, 'MEMORY.md'),
      skills: await WorkspaceFileService.readFile(agentName, 'SKILLS.md'),
      heartbeat: await WorkspaceFileService.readFile(agentName, 'HEARTBEAT.md'),
    );
  }

  /// Legacy load by agentId — resolves to name-based path.
  /// Used during migration period; prefer [load] with agent name.
  Future<AgentWorkspace> loadById(String agentId, {String? agentName}) async {
    if (agentName != null && agentName.isNotEmpty) {
      return load(agentName);
    }
    // Fallback: try legacy internal path.
    final legacyDir = await WorkspacePaths.getLegacyWorkspaceDir(agentId);
    if (await legacyDir.exists()) {
      return AgentWorkspace(
        soul: await _readFile(legacyDir, 'SOUL.md'),
        memory: await _readFile(legacyDir, 'MEMORY.md'),
        skills: await _readFile(legacyDir, 'SKILLS.md'),
        heartbeat: await _readFile(legacyDir, 'HEARTBEAT.md'),
      );
    }
    return AgentWorkspace(soul: '', memory: '', skills: '', heartbeat: '');
  }

  /// Update HEARTBEAT.md with current runtime state.
  Future<void> updateHeartbeat(
    String agentName, {
    required String state,
    required String task,
    String? lastTool,
    String? lastResult,
    String? lastError,
  }) async {
    final content = '''# Heartbeat

Current state: $state
Current task: $task
Last tool: ${lastTool ?? 'none'}
Last result: ${lastResult ?? 'none'}
Last error: ${lastError ?? 'none'}
Updated at: ${DateTime.now().toIso8601String()}
''';
    await WorkspaceFileService.writeFile(agentName, 'HEARTBEAT.md', content);
  }

  /// Ensure workspace directory exists with default files.
  Future<void> ensureWorkspace(String agentName, {String languageCode = 'id'}) async {
    final dir = await WorkspacePaths.getAgentWorkspace(agentName);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    await _ensureFile(dir, 'SOUL.md', _defaultSoul(agentName, languageCode));
    await _ensureFile(dir, 'MEMORY.md', _defaultMemory);
    await _ensureFile(dir, 'SKILLS.md', _defaultSkills);
    await _ensureFile(dir, 'HEARTBEAT.md', _defaultHeartbeat);
  }

  Future<String> _readFile(Directory dir, String filename) async {
    final file = File('${dir.path}/$filename');
    try {
      if (await file.exists()) {
        return file.readAsString();
      }
    } catch (_) {
      // Corrupted — return empty.
    }
    return '';
  }

  Future<void> _ensureFile(
      Directory dir, String filename, String defaultContent) async {
    final file = File('${dir.path}/$filename');
    if (!await file.exists()) {
      await file.writeAsString(defaultContent);
    }
  }

  static String _defaultSoul(String name, String lang) => '''# SOUL.md

## Agent Identity

Name: $name
Role: Android-native personal AI assistant.
Personality: Calm, helpful, practical, friendly.
Default Language: ${lang == 'id' ? 'Indonesian' : 'English'}.

---

## User Identity

Name: [Your Name]
Nickname: [Optional Nickname]
Preferred Language: ${lang == 'id' ? 'Indonesian' : 'English'}
Timezone: [Your Timezone]
''';

  static const _defaultMemory = '''# MEMORY.md

No memories recorded yet.
''';

  static const _defaultSkills = '''# SKILLS.md

## Overview

This file describes how this agent should approach using its available tools.
The actual list of runtime tools is system-managed and injected automatically.

---

## Tool Usage Preferences

- Prefer reading state before performing sensitive actions.
- Always confirm with the user before destructive operations.
- Avoid spamming notifications or system toggles.

---

## Constraints

- Respect the safety mode defined in SOUL.md.
- Never call sensitive tools without an explicit user request.
- Stop and ask if a tool fails or requires permission.
''';

  static const _defaultHeartbeat = '''# HEARTBEAT.md

Current state: idle
Current task: none
Last tool: none
Last result: none
Last error: none
Updated at: never
''';
}
