import '../workspace/workspace_paths.dart';

/// Manages the per-agent workspace folder on disk.
///
/// Phase 7: identity, memory, and runtime events all live in `meow_core.db`.
/// This service exists only to lazily create the folder skeleton so the
/// `files.*` tools have a stable place to read and write user-uploaded files.
class WorkspaceFolderService {
  /// Ensure the agent workspace directory exists. Best-effort — never throws.
  /// Call sites must remain resilient when the folder cannot be created
  /// (e.g. storage permission denied), since the runtime works entirely
  /// from SQLite and only needs the folder for explicit `files.*` tool calls.
  Future<void> ensureFolder(String agentName) async {
    try {
      final dir = await WorkspacePaths.getAgentWorkspace(agentName);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (_) {
      // Non-fatal.
    }
  }
}
