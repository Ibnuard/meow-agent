import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'runtime_models.dart';

/// Loads and manages agent workspace files (soul.md, memory.md, etc.).
class WorkspaceLoader {
  /// Load workspace for a given agent.
  Future<AgentWorkspace> load(String agentId) async {
    final dir = await _workspaceDir(agentId);
    return AgentWorkspace(
      soul: await _readFile(dir, 'soul.md'),
      memory: await _readFile(dir, 'memory.md'),
      skills: await _readFile(dir, 'skills.md'),
      heartbeat: await _readFile(dir, 'heartbeat.md'),
    );
  }

  /// Update heartbeat.md with current runtime state.
  Future<void> updateHeartbeat(
    String agentId, {
    required String state,
    required String task,
    String? lastTool,
    String? lastResult,
    String? lastError,
  }) async {
    final dir = await _workspaceDir(agentId);
    final file = File('${dir.path}/heartbeat.md');
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
  Future<void> ensureWorkspace(String agentId) async {
    final dir = await _workspaceDir(agentId);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    await _ensureFile(dir, 'soul.md', _defaultSoul);
    await _ensureFile(dir, 'memory.md', _defaultMemory);
    await _ensureFile(dir, 'skills.md', _defaultSkills);
    await _ensureFile(dir, 'heartbeat.md', _defaultHeartbeat);
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

const _defaultSoul = '''# Soul

You are a helpful AI assistant.
You follow instructions carefully and respond concisely.
''';

const _defaultMemory = '''# Memory

No memories recorded yet.
''';

const _defaultSkills = '''# Skills

## Available Tools

- clipboard.read: Read current clipboard text. Risk: safe.
- clipboard.write: Write text to clipboard. Risk: sensitive. Requires confirmation.
''';

const _defaultHeartbeat = '''# Heartbeat

Current state: idle
Current task: none
Last tool: none
Last result: none
Last error: none
Updated at: never
''';
