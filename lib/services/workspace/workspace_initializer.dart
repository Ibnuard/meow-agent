import 'dart:io';

import 'workspace_paths.dart';

/// Initializes workspace directory and default files for a new or existing agent.
///
/// Creates the external Documents workspace structure:
///   Documents/MeowAgent/Agents/{AgentName}/
///     ├── SOUL.md
///     ├── MEMORY.md
///     ├── SKILLS.md
///     ├── HEARTBEAT.md
///     ├── summaries/
///     ├── notes/
///     └── exports/
class WorkspaceInitializer {
  /// Initialize workspace for an agent. Creates directory and default files
  /// only if they don't already exist (safe to call multiple times).
  static Future<String> initialize({
    required String agentName,
    String languageCode = 'id',
  }) async {
    final dir = await WorkspacePaths.getAgentWorkspace(agentName);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Create subdirectories.
    await Directory('${dir.path}/summaries').create(recursive: true);
    await Directory('${dir.path}/notes').create(recursive: true);
    await Directory('${dir.path}/exports').create(recursive: true);

    // Generate default files only if missing.
    await _ensureFile(
      File('${dir.path}/SOUL.md'),
      _defaultSoul(agentName, languageCode),
    );
    await _ensureFile(
      File('${dir.path}/MEMORY.md'),
      _defaultMemory(agentName),
    );
    await _ensureFile(
      File('${dir.path}/SKILLS.md'),
      _defaultSkills(agentName),
    );
    await _ensureFile(
      File('${dir.path}/HEARTBEAT.md'),
      _defaultHeartbeat(),
    );

    return dir.path;
  }

  /// Ensure a file exists; create with default content if missing.
  static Future<void> _ensureFile(File file, String defaultContent) async {
    if (!await file.exists()) {
      await file.writeAsString(defaultContent);
    }
  }

  /// Delete workspace for an agent.
  static Future<void> deleteWorkspace(String agentName) async {
    final dir = await WorkspacePaths.getAgentWorkspace(agentName);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// Rename workspace directory when agent name changes.
  static Future<void> renameWorkspace(String oldName, String newName) async {
    final oldDir = await WorkspacePaths.getAgentWorkspace(oldName);
    if (!await oldDir.exists()) return;

    final newDir = await WorkspacePaths.getAgentWorkspace(newName);
    if (await newDir.exists()) return; // Don't overwrite existing.

    try {
      await oldDir.rename(newDir.path);
    } catch (_) {
      // Cross-device rename fails — copy instead.
      await newDir.create(recursive: true);
      await for (final entity in oldDir.list()) {
        if (entity is File) {
          await entity.copy('${newDir.path}/${entity.uri.pathSegments.last}');
        } else if (entity is Directory) {
          final subName = entity.uri.pathSegments.last;
          await Directory('${newDir.path}/$subName').create(recursive: true);
        }
      }
      await oldDir.delete(recursive: true);
    }
  }

  // ─── Default Templates ─────────────────────────────────────────────────────

  static String _defaultSoul(String agentName, String languageCode) {
    return '''# SOUL.md

## Agent Identity

Name: $agentName
Role: Android-native personal agentic AI assistant.
Personality: Calm, helpful, practical, friendly.

---

## User Identity

Name: [Your Name]
Nickname: [Optional Nickname]
Preferred Language: [Not set]
Timezone: [Your Timezone]

---

## Design Preference

<!-- Optional: how the agent should format its responses for you. -->

[Add your preferences here, e.g.:
- Response tone: warm / formal / casual
- Response length: short bullets / detailed paragraphs
- Formatting: emojis / no emojis / markdown]
''';
  }

  static String _defaultMemory(String agentName) => '''# MEMORY.md — $agentName

## Overview

This file stores persistent memory and context that carries across sessions.
The agent can read and append to this file to maintain long-term awareness.

---

## Facts

- Agent created: ${DateTime.now().toIso8601String().split('T').first}

---

## Session Notes

---

## Learned Preferences

---

## Bookmarks

''';

  static String _defaultSkills(String agentName) => '''# SKILLS.md — $agentName

## Overview

This file describes how this agent should approach using its available tools.
The actual list of runtime tools is system-managed and injected automatically.

---

## Tool Usage Preferences

- Prefer reading state before performing sensitive actions.
- Always confirm with the user before destructive operations.
- Avoid spamming notifications or system toggles.

---

## Custom Skills / Workflows

```yaml
skills: []
```

---

## Constraints

- Respect the safety mode defined in SOUL.md.
- Never call sensitive tools without an explicit user request.
- Stop and ask if a tool fails or requires permission.
''';

  static String _defaultHeartbeat() => '''# HEARTBEAT.md

Current state: idle
Current task: none
Last tool: none
Last result: none
Last error: none
Updated at: never
''';
}
