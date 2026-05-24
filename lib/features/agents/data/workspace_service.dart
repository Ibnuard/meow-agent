import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../settings/data/app_language_provider.dart';

/// Manages per-agent workspace folders.
///
/// Each agent gets a folder at:
///   `{appDocDir}/workspaces/{agentId}/`
///
/// Inside each workspace, 4 template files are generated on creation:
///   - SKILLS.md  — defines what tools/modules the agent can use
///   - SOUL.md    — defines the agent's personality and system prompt
///   - HEARTBEAT.md — defines periodic/background behaviors
///   - MEMORY.md  — persistent memory and context across sessions
class WorkspaceService {
  /// Creates the workspace folder and generates template files for a new agent.
  ///
  /// If the workspace already exists (e.g. editing an agent), this is a no-op.
  Future<String> createWorkspace({
    required String agentId,
    required String agentName,
    String languageCode = 'en',
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final workspaceDir = Directory('${appDir.path}/workspaces/$agentId');

    if (await workspaceDir.exists()) {
      return workspaceDir.path;
    }

    await workspaceDir.create(recursive: true);

    // Generate template files.
    await File('${workspaceDir.path}/SKILLS.md')
        .writeAsString(_skillTemplate(agentName));
    await File('${workspaceDir.path}/SOUL.md')
        .writeAsString(_soulTemplate(agentName, languageCode));
    await File('${workspaceDir.path}/HEARTBEAT.md')
        .writeAsString(_heartbeatTemplate(agentName));
    await File('${workspaceDir.path}/MEMORY.md')
        .writeAsString(_memoryTemplate(agentName));

    return workspaceDir.path;
  }

  /// Returns the workspace path for an agent, or null if it doesn't exist.
  /// Also migrates any legacy lowercase files (one-time cleanup).
  Future<String?> getWorkspacePath(String agentId) async {
    final appDir = await getApplicationDocumentsDirectory();
    final workspaceDir = Directory('${appDir.path}/workspaces/$agentId');
    if (await workspaceDir.exists()) {
      await _migrateLegacyFiles(workspaceDir);
      return workspaceDir.path;
    }
    return null;
  }

  /// One-time cleanup: copy lowercase files to UPPERCASE and delete duplicates.
  /// Also migrates legacy SKILL.md → SKILLS.md.
  Future<void> _migrateLegacyFiles(Directory dir) async {
    const pairs = {
      'soul.md': 'SOUL.md',
      'memory.md': 'MEMORY.md',
      'skills.md': 'SKILLS.md',
      'heartbeat.md': 'HEARTBEAT.md',
    };
    for (final entry in pairs.entries) {
      final lower = File('${dir.path}/${entry.key}');
      final upper = File('${dir.path}/${entry.value}');
      if (await lower.exists()) {
        if (!await upper.exists()) {
          await upper.writeAsString(await lower.readAsString());
        }
        try {
          await lower.delete();
        } catch (_) {/* ignore */}
      }
    }

    // Legacy SKILL.md (uppercase singular) → SKILLS.md (plural).
    final legacySkill = File('${dir.path}/SKILL.md');
    final newSkills = File('${dir.path}/SKILLS.md');
    if (await legacySkill.exists()) {
      if (!await newSkills.exists()) {
        await newSkills.writeAsString(await legacySkill.readAsString());
      }
      try {
        await legacySkill.delete();
      } catch (_) {/* ignore */}
    }
  }

  /// Deletes the workspace folder for an agent.
  Future<void> deleteWorkspace(String agentId) async {
    final appDir = await getApplicationDocumentsDirectory();
    final workspaceDir = Directory('${appDir.path}/workspaces/$agentId');
    if (await workspaceDir.exists()) {
      await workspaceDir.delete(recursive: true);
    }
  }

  // ─── Templates ──────────────────────────────────────────────────────

  String _skillTemplate(String agentName) => '''# SKILLS.md — $agentName

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

  String _soulTemplate(String agentName, String languageCode) {
    final language = languageLabelFromCode(languageCode);
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

Default Language:
$language

---

## User Identity

Name: [Your Name]
Nickname: [Optional Nickname]
Preferred Language: $language
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

  String _heartbeatTemplate(String agentName) => '''# HEARTBEAT.md — $agentName

## Overview

This file defines periodic and background behaviors for this agent.
Heartbeat tasks run on a schedule or in response to system events.

---

## Scheduled Tasks

<!-- Define recurring tasks. Format: cron-like description + action. -->

```yaml
tasks: []
```

### Examples (inactive)

```yaml
# - schedule: "every 30 minutes"
#   action: "Check notification queue and summarize unread"
#
# - schedule: "daily at 09:00"
#   action: "Generate daily briefing from saved sources"
```

---

## Event Triggers

<!-- Define actions triggered by system events. -->

```yaml
triggers: []
```

### Examples (inactive)

```yaml
# - event: "notification_received"
#   filter: "package:com.bank.app"
#   action: "Extract amount and log to expense tracker"
#
# - event: "wifi_connected"
#   filter: "ssid:HomeNetwork"
#   action: "Sync pending file uploads"
```

---

## Background Rules

- Heartbeat tasks must respect the safety mode in SOUL.md.
- Tasks that modify data or send network requests require approval unless autonomous mode is enabled.
- Failed tasks should be logged, not retried silently.
- Maximum background execution time per task: 30 seconds.
''';

  String _memoryTemplate(String agentName) => '''# MEMORY.md — $agentName

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
