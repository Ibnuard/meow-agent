import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'runtime_models.dart';

/// Loads and manages agent workspace files.
/// Standardized on UPPERCASE filenames matching the UI's WorkspaceService:
///   - SOUL.md
///   - MEMORY.md
///   - SKILLS.md
///   - HEARTBEAT.md
class WorkspaceLoader {
  /// Load workspace for a given agent.
  Future<AgentWorkspace> load(String agentId) async {
    final dir = await _workspaceDir(agentId);
    return AgentWorkspace(
      soul: await _readFile(dir, 'SOUL.md'),
      memory: await _readFile(dir, 'MEMORY.md'),
      skills: await _readFile(dir, 'SKILLS.md'),
      heartbeat: await _readFile(dir, 'HEARTBEAT.md'),
    );
  }

  /// Update HEARTBEAT.md with current runtime state.
  Future<void> updateHeartbeat(
    String agentId, {
    required String state,
    required String task,
    String? lastTool,
    String? lastResult,
    String? lastError,
  }) async {
    final dir = await _workspaceDir(agentId);
    final file = File('${dir.path}/HEARTBEAT.md');
    final content = '''# Heartbeat

Current state: $state
Current task: $task
Last tool: ${lastTool ?? 'none'}
Last result: ${lastResult ?? 'none'}
Last error: ${lastError ?? 'none'}
Updated at: ${DateTime.now().toIso8601String()}
''';
    await file.writeAsString(content);
  }

  /// Ensure workspace directory exists with default files.
  /// Migrates legacy lowercase files to UPPERCASE.
  Future<void> ensureWorkspace(String agentId) async {
    final dir = await _workspaceDir(agentId);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    // Migrate legacy lowercase files (one-time cleanup).
    await _migrateLegacy(dir);

    await _ensureFile(dir, 'SOUL.md', _defaultSoul);
    await _ensureFile(dir, 'MEMORY.md', _defaultMemory);
    await _ensureFile(dir, 'SKILLS.md', _defaultSkills);
    await _ensureFile(dir, 'HEARTBEAT.md', _defaultHeartbeat);

    // One-time cleanup: strip legacy auto-injected runtime tool block.
    await _cleanupLegacyToolBlock(dir);
    // One-time cleanup: strip legacy system-rule sections from SOUL.md.
    await _cleanupLegacySoulSections(dir);
  }

  /// One-time migration: copy lowercase content to UPPERCASE if UPPERCASE missing,
  /// then delete lowercase duplicates. Also migrates legacy SKILL.md → SKILLS.md.
  Future<void> _migrateLegacy(Directory dir) async {
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
        await lower.delete();
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

  /// Refresh SKILLS.md while preserving custom sections above the tool list.
  /// One-time cleanup: strip legacy auto-injected `<!-- BEGIN_RUNTIME_TOOLS -->`
  /// block from existing SKILLS.md. Runtime tools now come from the ToolRouter
  /// registry, not from this file.
  Future<void> _cleanupLegacyToolBlock(Directory dir) async {
    final file = File('${dir.path}/SKILLS.md');
    if (!await file.exists()) return;

    const marker = '<!-- BEGIN_RUNTIME_TOOLS -->';
    const endMarker = '<!-- END_RUNTIME_TOOLS -->';

    var content = await file.readAsString();
    if (!content.contains(marker) || !content.contains(endMarker)) return;

    final start = content.indexOf(marker);
    final end = content.indexOf(endMarker) + endMarker.length;
    final stripped = (content.substring(0, start) + content.substring(end))
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    await file.writeAsString('$stripped\n');
  }

  /// One-time cleanup: strip legacy system-rule sections from SOUL.md.
  /// These rules (First Introduction, Identity Update, Behavior Rules, hardcoded
  /// Design Preference) are now enforced by the runtime, not the user template.
  Future<void> _cleanupLegacySoulSections(Directory dir) async {
    final file = File('${dir.path}/SOUL.md');
    if (!await file.exists()) return;

    var content = await file.readAsString();
    const sectionsToStrip = [
      '## First Introduction Rule',
      '## Identity Update Rule',
      '## Behavior Rules',
      '## Design Preference',
    ];

    var changed = false;
    for (final heading in sectionsToStrip) {
      final start = content.indexOf(heading);
      if (start == -1) continue;

      // Find end: next `## ` heading or EOF.
      final after = content.indexOf(
          RegExp(r'^## ', multiLine: true), start + heading.length);
      final end = after == -1 ? content.length : after;

      // Walk back over any preceding `---` separator + blank lines.
      var sliceStart = start;
      final preceding = content.substring(0, start);
      final sepRegex = RegExp(r'\n*\s*---\s*\n*$');
      final sepMatch = sepRegex.firstMatch(preceding);
      if (sepMatch != null) {
        sliceStart = sepMatch.start;
      }

      content = content.substring(0, sliceStart) + content.substring(end);
      changed = true;
    }

    if (!changed) return;

    // Re-add an empty Design Preference template if missing.
    if (!content.contains('## Design Preference')) {
      content = '${content.trimRight()}\n\n---\n\n## Design Preference\n\n'
          '<!-- Optional: how the agent should format its responses for you. -->\n\n'
          '[Add your preferences here, e.g.:\n'
          '- Response tone: warm / formal / casual\n'
          '- Response length: short bullets / detailed paragraphs\n'
          '- Formatting: emojis / no emojis / markdown]\n';
    }

    // Collapse any 3+ consecutive blank lines.
    content = content.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    await file.writeAsString('$content\n');
  }

  Future<Directory> _workspaceDir(String agentId) async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory('${appDir.path}/workspaces/$agentId');
  }

  Future<String> _readFile(Directory dir, String filename) async {
    final file = File('${dir.path}/$filename');
    if (await file.exists()) {
      return file.readAsString();
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
}

const _defaultSoul = '''# SOUL.md

## Agent Identity

Name: Meow
Role: Android-native personal AI assistant.
Personality: Calm, helpful, practical, friendly.
Default Language: Indonesian.

---

## User Identity

Name: [Your Name]
Nickname: [Optional Nickname]
Preferred Language: Indonesian
Timezone: [Your Timezone]
''';

const _defaultMemory = '''# MEMORY.md

No memories recorded yet.
''';

const _defaultSkills = '''# SKILLS.md

## Overview

This file describes how this agent should approach using its available tools.
The actual list of runtime tools is system-managed and injected automatically.

---

## Tool Usage Preferences

<!-- Describe how this agent should prefer or avoid certain tool categories. -->

- Prefer reading state before performing sensitive actions.
- Always confirm with the user before destructive operations.
- Avoid spamming notifications or system toggles.

---

## Custom Skills / Workflows

<!-- Define multi-step skills the agent can follow. Example below. -->

```yaml
skills:
  - name: morning_briefing
    description: Summarize device status when asked for a daily briefing.
    steps:
      - device.summary
      - reply_with_friendly_summary
```

---

## Constraints

- Respect the safety mode defined in SOUL.md.
- Never call sensitive tools without an explicit user request.
- Stop and ask if a tool fails or requires permission.
''';


const _defaultHeartbeat = '''# HEARTBEAT.md

Current state: idle
Current task: none
Last tool: none
Last result: none
Last error: none
Updated at: never
''';
