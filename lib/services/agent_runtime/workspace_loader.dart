import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'runtime_models.dart';

/// Loads and manages agent workspace files.
/// Standardized on UPPERCASE filenames matching the UI's WorkspaceService:
///   - SOUL.md
///   - MEMORY.md
///   - SKILL.md
///   - HEARTBEAT.md
class WorkspaceLoader {
  /// Load workspace for a given agent.
  Future<AgentWorkspace> load(String agentId) async {
    final dir = await _workspaceDir(agentId);
    return AgentWorkspace(
      soul: await _readFile(dir, 'SOUL.md'),
      memory: await _readFile(dir, 'MEMORY.md'),
      skills: await _readFile(dir, 'SKILL.md'),
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
    // Always refresh SKILL.md tool list so new tools are available.
    await _refreshSkills(dir);
    await _ensureFile(dir, 'HEARTBEAT.md', _defaultHeartbeat);
  }

  /// One-time migration: copy lowercase content to UPPERCASE if UPPERCASE missing,
  /// then delete lowercase duplicates.
  Future<void> _migrateLegacy(Directory dir) async {
    const pairs = {
      'soul.md': 'SOUL.md',
      'memory.md': 'MEMORY.md',
      'skills.md': 'SKILL.md',
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
  }

  /// Refresh SKILL.md while preserving custom sections above the tool list.
  Future<void> _refreshSkills(Directory dir) async {
    final file = File('${dir.path}/SKILL.md');
    final marker = '<!-- BEGIN_RUNTIME_TOOLS -->';
    final endMarker = '<!-- END_RUNTIME_TOOLS -->';

    String existing = '';
    if (await file.exists()) {
      existing = await file.readAsString();
    }

    final toolBlock = '$marker\n$_defaultSkillsBlock\n$endMarker';

    if (existing.contains(marker) && existing.contains(endMarker)) {
      // Replace the existing tool block.
      final start = existing.indexOf(marker);
      final end = existing.indexOf(endMarker) + endMarker.length;
      existing = existing.substring(0, start) + toolBlock + existing.substring(end);
      await file.writeAsString(existing);
    } else if (existing.isEmpty) {
      // Fresh file — write defaults.
      await file.writeAsString('$_defaultSkillsHeader\n\n$toolBlock\n');
    } else {
      // Existing custom content — append tool block at end.
      await file.writeAsString('$existing\n\n$toolBlock\n');
    }
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

You are a helpful AI assistant running on Android.
You can call tools to control apps, clipboard, and system settings.
Respond concisely and follow instructions carefully.
''';

const _defaultMemory = '''# MEMORY.md

No memories recorded yet.
''';

const _defaultSkillsHeader = '''# SKILL.md

This file lists tools and modules this agent can use.
Custom notes can be added above or below the runtime tools section.''';

const _defaultSkillsBlock = '''## Available Runtime Tools

### Clipboard
- clipboard.read: Read current clipboard text. Risk: safe.
- clipboard.write: Write text to clipboard. Risk: sensitive. Requires confirmation.

### App Control
- app.resolve: Resolve a friendly app name to a package. Use this BEFORE app.open. Risk: safe. Args: query (string).
- app.open: Open an app by package name (use app.resolve first). Risk: sensitive. Requires confirmation. Args: package (string).
- app.list_installed: List all installed launchable apps. Risk: safe.
- settings.open: Open Android system settings. Risk: safe. Args: action (optional).
- intent.open_url: Open a URL in the default browser. Risk: sensitive. Requires confirmation. Args: url (string).

### Device Context
- device.battery: Read current battery level and charging status. Risk: safe.
- device.network: Read current network connection type and status. Risk: safe.
- device.storage: Read current device storage usage. Risk: safe.
- device.time: Read current local device time and timezone. Risk: safe.
- device.locale: Read device language and locale. Risk: safe.
- device.summary: Read a summary of battery, network, storage, time, and locale. Risk: safe.
- device.foreground_app: Read the app CURRENTLY in the foreground RIGHT NOW only. Does NOT provide usage history or screen time stats. Risk: safe.
- device.usage_stats: Read real app usage statistics for the past N days. Returns top 10 user-facing apps sorted by total usage time in minutes. USE THIS when asked about most-used apps, screen time, or app usage history. Args: days (int, optional, default 7). Risk: safe.''';

const _defaultHeartbeat = '''# HEARTBEAT.md

Current state: idle
Current task: none
Last tool: none
Last result: none
Last error: none
Updated at: never
''';
