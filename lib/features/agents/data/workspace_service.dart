import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/workspace/workspace_file_service.dart';
import '../../../services/workspace/workspace_initializer.dart';
import '../../../services/workspace/workspace_paths.dart';

/// Manages per-agent workspace folders in external Documents storage.
///
/// Each agent gets a folder at:
///   `/Documents/MeowAgent/Agents/{AgentName}/`
///
/// Inside each workspace, 4 template files are generated on creation:
///   - SOUL.md    — defines the agent's personality and system prompt
///   - MEMORY.md  — persistent memory and context across sessions
///   - SKILLS.md  — defines what tools/modules the agent can use
///   - HEARTBEAT.md — defines periodic/background behaviors
class WorkspaceService {
  static const _channel = MethodChannel('com.meowagent.meow_agent/storage');

  /// Creates the workspace folder and generates template files for a new agent.
  ///
  /// If the workspace already exists, this is a no-op (files not overwritten).
  Future<String> createWorkspace({
    required String agentId,
    required String agentName,
    String languageCode = 'en',
  }) async {
    return WorkspaceInitializer.initialize(
      agentName: agentName,
      languageCode: languageCode,
    );
  }

  /// Returns the workspace path for an agent, or null if it doesn't exist.
  Future<String?> getWorkspacePath(String agentId, {String? agentName}) async {
    if (agentName != null && agentName.isNotEmpty) {
      final dir = await WorkspacePaths.getAgentWorkspace(agentName);
      if (await dir.exists()) {
        return dir.path;
      }
    }

    // Fallback: check legacy internal path.
    final legacyDir = await WorkspacePaths.getLegacyWorkspaceDir(agentId);
    if (await legacyDir.exists()) {
      return legacyDir.path;
    }
    return null;
  }

  /// Get the display-friendly workspace path.
  Future<String> getDisplayPath(String agentName) async {
    return WorkspaceFileService.getWorkspaceDisplayPath(agentName);
  }

  /// Read a workspace file.
  Future<String> readFile(String agentName, String filename) async {
    return WorkspaceFileService.readFile(agentName, filename);
  }

  /// Write a workspace file.
  Future<void> writeFile(String agentName, String filename, String content) async {
    await WorkspaceFileService.writeFile(agentName, filename, content);
  }

  /// Deletes the workspace folder for an agent.
  Future<void> deleteWorkspace(String agentName) async {
    await WorkspaceInitializer.deleteWorkspace(agentName);
  }

  /// Rename workspace when agent name changes.
  Future<void> renameWorkspace(String oldName, String newName) async {
    await WorkspaceInitializer.renameWorkspace(oldName, newName);
  }

  /// Open workspace folder in Android file manager.
  Future<bool> openInFileManager(String agentName) async {
    try {
      // Ensure directory exists first.
      final dir = await WorkspacePaths.getAgentWorkspace(agentName);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final result = await _channel.invokeMethod<bool>(
        'openWorkspaceFolder',
        {'path': dir.path},
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  // ─── Templates (kept for backward compatibility) ────────────────────────

  String skillTemplate(String agentName) => '''# SKILLS.md — $agentName

## Overview

This file defines the tools and modules available to this agent.
Only enabled modules listed here can be invoked during a session.

---

## Enabled Modules

<!-- Add modules this agent is allowed to use. -->

- [ ] Browser Module
- [ ] File Module
- [ ] Webhook/API Module
- [ ] Notification Listener Module
- [ ] VM Module
- [ ] Intent Module

---

## Custom Tools

<!-- Define custom tool schemas the agent can call. -->

```yaml
tools: []
```

---

## Constraints

- Only use modules that are checked above.
- Never assume a module is available unless explicitly enabled.
- Respect the safety mode defined in SOUL.md.
''';

  String soulTemplate(String agentName, String languageCode) {
    return '''# SOUL.md

## Agent Identity

Name: $agentName

Role:
Android-native personal agentic AI assistant.

Personality:
- Calm
- Helpful
- Practical
- Friendly

---

## User Identity

Name: [Your Name]
Nickname: [Optional Nickname]
Preferred Language: [Not set]
Timezone: [Your Timezone]

Work/Role: [Your Role]
Main Projects:
- [Project Name]

Communication Style:
- Clear
- Practical
- Minimal

---

## Design Preference

<!-- Optional: how the agent should format its responses for you. -->

[Add your preferences here, e.g.:
- Response tone: warm / formal / casual
- Response length: short bullets / detailed paragraphs
- Formatting: emojis / no emojis / markdown]
''';
  }

  String heartbeatTemplate(String agentName) => '''# HEARTBEAT.md — $agentName

## Overview

This file defines periodic and background behaviors for this agent.
Heartbeat tasks run on a schedule or in response to system events.

---

## Scheduled Tasks

<!-- Define recurring tasks. Format: cron-like description + action. -->

```yaml
tasks: []
```

---

## Event Triggers

<!-- Define actions triggered by system events. -->

```yaml
triggers: []
```

---

## Background Rules

- Heartbeat tasks must respect the safety mode in SOUL.md.
- Tasks that modify data or send network requests require approval unless autonomous mode is enabled.
- Failed tasks should be logged, not retried silently.
- Maximum background execution time per task: 30 seconds.
''';

  String memoryTemplate(String agentName) => '''# MEMORY.md — $agentName

## Overview

This file stores persistent memory and context that carries across sessions.
The agent can read and append to this file to maintain long-term awareness.

---

## Facts

<!-- Key facts the agent should always remember. -->

- Agent created: (auto-filled on first run)
- Owner preferences: (to be learned)

---

## Session Notes

<!-- The agent appends important context here after each session. -->

---

## Learned Preferences

<!-- Patterns the agent has observed about the user. -->

---

## Bookmarks

<!-- Important references, URLs, file paths, or data the agent should recall. -->

---

## Rules

- Memory entries should be concise (1-2 lines each).
- Remove outdated entries periodically.
- Never store sensitive data (passwords, tokens, OTPs) in memory.
- Maximum file size: 50KB. Prune oldest entries if exceeded.
''';
}

final workspaceServiceProvider = Provider<WorkspaceService>(
  (ref) => WorkspaceService(),
);
