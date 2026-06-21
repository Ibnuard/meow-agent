import 'dart:io';

import 'workspace_paths.dart';

/// Creates the per-agent workspace folder for user files.
///
/// Phase 7 architecture: identity (SOUL), long-term memory (MEMORY), and
/// runtime heartbeat (HEARTBEAT) all live in `meow_core.db` — they are NOT
/// materialized as markdown files anymore. This initializer only creates
/// the folder skeleton so the `files.*` tools have a stable place to read
/// and write user-uploaded documents.
///
/// Layout:
///   Documents/MeowAgent/Agents/{AgentName}/
///     ├── summaries/
///     ├── notes/
///     └── exports/
class WorkspaceInitializer {
  /// Create the workspace folder skeleton if missing. Safe to call multiple
  /// times — pre-existing files and folders are left alone.
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

    return dir.path;
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
}
