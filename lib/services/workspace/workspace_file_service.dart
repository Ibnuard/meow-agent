import 'dart:io';

import 'workspace_paths.dart';

/// Service for reading and writing workspace files.
///
/// All workspace file I/O should go through this service to ensure
/// consistent path resolution and graceful error handling.
class WorkspaceFileService {
  /// Read a workspace file. Returns empty string if missing/corrupted.
  /// Recreates the file with default content if missing.
  static Future<String> readFile(String agentName, String filename) async {
    final dir = await WorkspacePaths.getAgentWorkspace(agentName);
    final file = File('${dir.path}/$filename');

    try {
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (_) {
      // Corrupted file — return empty, will be recreated on next write.
    }
    return '';
  }

  /// Write content to a workspace file.
  static Future<void> writeFile(
    String agentName,
    String filename,
    String content,
  ) async {
    final dir = await WorkspacePaths.getAgentWorkspace(agentName);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File('${dir.path}/$filename');
    await file.writeAsString(content);
  }

  /// Check if a workspace file exists.
  static Future<bool> fileExists(String agentName, String filename) async {
    final dir = await WorkspacePaths.getAgentWorkspace(agentName);
    return File('${dir.path}/$filename').exists();
  }

  /// Write a compact summary snapshot.
  static Future<void> writeSummarySnapshot(
    String agentName,
    String summary,
  ) async {
    final summariesDir = await WorkspacePaths.getSummariesDir(agentName);
    if (!await summariesDir.exists()) {
      await summariesDir.create(recursive: true);
    }

    final date = DateTime.now().toIso8601String().split('T').first;
    final file = File('${summariesDir.path}/compact_$date.md');
    final content = '''# Compact Summary — $date

$summary
''';
    await file.writeAsString(content);
  }

  /// Export a note as markdown to the notes directory.
  static Future<void> exportNote(
    String agentName, {
    required String title,
    required String content,
    List<String> tags = const [],
  }) async {
    final notesDir = await WorkspacePaths.getNotesDir(agentName);
    if (!await notesDir.exists()) {
      await notesDir.create(recursive: true);
    }

    final safeName = title
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
    final file = File('${notesDir.path}/$safeName.md');

    final buf = StringBuffer()
      ..writeln('# $title')
      ..writeln();
    if (tags.isNotEmpty) {
      buf.writeln('Tags: ${tags.join(', ')}');
      buf.writeln();
    }
    buf.write(content);

    await file.writeAsString(buf.toString());
  }

  /// Get the workspace directory path string for display.
  static Future<String> getWorkspaceDisplayPath(String agentName) async {
    final dir = await WorkspacePaths.getAgentWorkspace(agentName);
    return dir.path;
  }
}
