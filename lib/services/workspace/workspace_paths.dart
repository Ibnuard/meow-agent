import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Centralized path helpers for the external workspace.
///
/// Workspace files live in:
///   /storage/emulated/0/Documents/MeowAgent/Agents/{AgentName}/
///
/// This makes them visible in Android file managers without
/// requiring MANAGE_EXTERNAL_STORAGE permission.
class WorkspacePaths {
  WorkspacePaths._();

  static const _channel = MethodChannel('com.meowagent.meow_agent/storage');

  /// Cache the resolved documents path.
  static String? _cachedDocsPath;

  /// Get the public Documents directory path.
  /// Falls back to app-specific external storage if unavailable.
  static Future<String> getDocumentsPath() async {
    if (_cachedDocsPath != null) return _cachedDocsPath!;

    try {
      final path = await _channel.invokeMethod<String>('getDocumentsPath');
      if (path != null && path.isNotEmpty) {
        _cachedDocsPath = path;
        return path;
      }
    } catch (_) {
      // MethodChannel not available or failed — fallback.
    }

    // Fallback: use app-specific external directory.
    final extDir = await getExternalStorageDirectory();
    if (extDir != null) {
      _cachedDocsPath = '${extDir.path}/Documents';
      return _cachedDocsPath!;
    }

    // Last resort: internal app documents.
    final appDir = await getApplicationDocumentsDirectory();
    _cachedDocsPath = appDir.path;
    return _cachedDocsPath!;
  }

  /// Root directory for all MeowAgent workspace data.
  /// `/Documents/MeowAgent/`
  static Future<Directory> getMeowRoot() async {
    final docs = await getDocumentsPath();
    return Directory('$docs/MeowAgent');
  }

  /// Root directory for all agent workspaces.
  /// `/Documents/MeowAgent/Agents/`
  static Future<Directory> getAgentsRoot() async {
    final root = await getMeowRoot();
    return Directory('${root.path}/Agents');
  }

  /// Workspace directory for a specific agent.
  /// `/Documents/MeowAgent/Agents/{agentName}/`
  static Future<Directory> getAgentWorkspace(String agentName) async {
    final agentsRoot = await getAgentsRoot();
    final safeName = _sanitizeName(agentName);
    return Directory('${agentsRoot.path}/$safeName');
  }

  /// Get the SOUL.md file for an agent.
  static Future<File> getSoulFile(String agentName) async {
    final dir = await getAgentWorkspace(agentName);
    return File('${dir.path}/SOUL.md');
  }

  /// Get the MEMORY.md file for an agent.
  static Future<File> getMemoryFile(String agentName) async {
    final dir = await getAgentWorkspace(agentName);
    return File('${dir.path}/MEMORY.md');
  }

  /// Get the SKILLS.md file for an agent.
  static Future<File> getSkillsFile(String agentName) async {
    final dir = await getAgentWorkspace(agentName);
    return File('${dir.path}/SKILLS.md');
  }

  /// Get the HEARTBEAT.md file for an agent.
  static Future<File> getHeartbeatFile(String agentName) async {
    final dir = await getAgentWorkspace(agentName);
    return File('${dir.path}/HEARTBEAT.md');
  }

  /// Get the summaries directory for an agent.
  static Future<Directory> getSummariesDir(String agentName) async {
    final dir = await getAgentWorkspace(agentName);
    return Directory('${dir.path}/summaries');
  }

  /// Get the notes export directory for an agent.
  static Future<Directory> getNotesDir(String agentName) async {
    final dir = await getAgentWorkspace(agentName);
    return Directory('${dir.path}/notes');
  }

  /// Get the exports directory for an agent.
  static Future<Directory> getExportsDir(String agentName) async {
    final dir = await getAgentWorkspace(agentName);
    return Directory('${dir.path}/exports');
  }

  /// Legacy internal workspace path (for migration).
  static Future<Directory> getLegacyWorkspaceDir(String agentId) async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory('${appDir.path}/workspaces/$agentId');
  }

  /// Sanitize agent name for filesystem use.
  static String _sanitizeName(String name) {
    return name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
  }
}
