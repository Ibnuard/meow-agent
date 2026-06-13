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
/// Phase 7: identity, long-term memory, and runtime events all live in
/// `meow_core.db`. The workspace folder is for user files only (uploads,
/// PDFs, exports) — accessed via the `files.*` tools when the user asks.
class WorkspaceService {
  static const _channel = MethodChannel('com.meowagent.meow_agent/storage');

  /// Creates the workspace folder for a new agent.
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
}

final workspaceServiceProvider = Provider<WorkspaceService>(
  (ref) => WorkspaceService(),
);
