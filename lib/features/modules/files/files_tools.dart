import 'dart:io';

import '../../../services/agent_runtime/runtime_models.dart';
import '../../../services/workspace/workspace_paths.dart';
import '../data/module_repository.dart';

/// Executes file-related tool calls.
/// All operations are sandboxed to the agent's workspace directory.
class FilesTools {
  FilesTools({required this.agentName, ModuleRepository? moduleRepository})
    : _moduleRepository = moduleRepository ?? ModuleRepository();

  final String agentName;
  final ModuleRepository _moduleRepository;

  /// Check if the files module is enabled and a specific setting is allowed.
  Future<bool> _isAllowed(String settingKey) async {
    final modules = await _moduleRepository.getInstalled();
    final filesMod = modules.where((m) => m.id == 'files').firstOrNull;
    if (filesMod == null || !filesMod.enabled) return false;
    return filesMod.settings[settingKey] ?? true;
  }

  /// Resolve and validate a path. The sandbox boundary is the MeowAgent
  /// root (`/Documents/MeowAgent/`), NOT the calling agent's own workspace.
  /// This lets agents read/write peer workspaces (e.g. swap personalities)
  /// while still preventing traversal to arbitrary device paths.
  ///
  /// A path can be supplied in three forms:
  /// - relative (`SOUL.md`, `notes/foo.md`) → resolved against the calling
  ///   agent's own workspace.
  /// - workspace-relative (`Agents/Penulis/SOUL.md`) → resolved against the
  ///   MeowAgent root, which lets agents reach peer workspaces.
  /// - absolute (`/storage/emulated/0/Documents/MeowAgent/...`) → accepted
  ///   only when the absolute path stays under MeowAgent root.
  ///
  /// Returns null when the resolved path escapes MeowAgent root (security).
  Future<String?> _resolveSafePath(String relativePath) async {
    final result = await _resolveWithMeta(relativePath);
    return result?.path;
  }

  /// Same resolution as [_resolveSafePath] but also tells the caller whether
  /// the resolved path is OUTSIDE the calling agent's own workspace so the
  /// runtime can decide whether to require confirmation.
  Future<_ResolvedPath?> _resolveWithMeta(String relativePath) async {
    final wsDir = await WorkspacePaths.getAgentWorkspace(agentName);
    final root = await WorkspacePaths.getMeowRoot();
    final wsNorm = Directory(wsDir.path).absolute.path;
    final rootNorm = Directory(root.path).absolute.path;

    // Normalize separators — keep absolute markers intact.
    var cleaned = relativePath.replaceAll('\\', '/');
    if (cleaned.contains('..')) return null; // No traversal up.

    String resolvedRaw;
    if (cleaned.startsWith('/')) {
      // Caller passed an absolute path. Accept only when it's under
      // MeowAgent root to keep arbitrary device paths out of reach.
      resolvedRaw = cleaned;
    } else if (cleaned.startsWith('Agents/') || cleaned.startsWith('agents/')) {
      // Workspace-relative: resolve against MeowAgent root so agents can
      // address peer workspaces by `Agents/<Name>/SOUL.md`.
      resolvedRaw = '$rootNorm/$cleaned';
    } else {
      // Default: relative to own workspace, same as before the widening.
      resolvedRaw = '${wsDir.path}/$cleaned';
    }

    final resolvedNorm = File(resolvedRaw).absolute.path;

    // Hard boundary: must stay under MeowAgent root.
    if (!resolvedNorm.startsWith(rootNorm)) return null;

    final isOutsideOwn = !resolvedNorm.startsWith(wsNorm);
    return _ResolvedPath(resolvedNorm, isOutsideOwn);
  }

  /// Public preflight: tells the runtime whether [relativePath] would land
  /// outside the calling agent's own workspace. The runtime escalates such
  /// calls to a confirmation gate even when the tool is normally "safe".
  /// Returns false when the path is invalid — the actual tool execution
  /// will surface the error.
  Future<bool> isCrossWorkspacePath(String relativePath) async {
    final meta = await _resolveWithMeta(relativePath);
    return meta?.isOutsideOwnWorkspace ?? false;
  }

  // ─── files.create ──────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeCreate(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_create')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'files.create',
        error: 'Files module is disabled or create not allowed.',
      );
    }
    try {
      final path = (args['path'] as String? ?? '').trim();
      final content = args['content'] as String? ?? '';

      if (path.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.create',
          error: 'path is required.',
        );
      }

      final resolved = await _resolveSafePath(path);
      if (resolved == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.create',
          error: 'Invalid path: cannot escape workspace.',
        );
      }

      final file = File(resolved);
      if (await file.exists()) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.create',
          error: 'File already exists. Use files.write to overwrite.',
        );
      }

      // Ensure parent directory exists.
      await file.parent.create(recursive: true);
      await file.writeAsString(content);

      return ToolExecutionResult(
        success: true,
        toolName: 'files.create',
        data: {'created': true, 'path': path},
        actions: [
          ResultAction(
            label: 'Open File Manager',
            labelId: 'Buka File Manager',
            icon: 'folder_open_rounded',
            type: 'open_folder',
            target: agentName,
          ),
        ],
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'files.create',
        error: e.toString(),
      );
    }
  }

  // ─── files.read ────────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeRead(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'files.read',
        error: 'Files module is disabled or read not allowed.',
      );
    }
    try {
      final path = (args['path'] as String? ?? '').trim();
      if (path.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.read',
          error: 'path is required.',
        );
      }

      final resolved = await _resolveSafePath(path);
      if (resolved == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.read',
          error: 'Invalid path: cannot escape workspace.',
        );
      }

      final file = File(resolved);
      if (!await file.exists()) {
        return ToolExecutionResult(
          success: false,
          toolName: 'files.read',
          error: 'File not found: $path',
        );
      }

      final content = await file.readAsString();
      final stat = await file.stat();

      return ToolExecutionResult(
        success: true,
        toolName: 'files.read',
        data: {
          'path': path,
          'content': content,
          'size': stat.size,
          'modified': stat.modified.toIso8601String(),
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'files.read',
        error: e.toString(),
      );
    }
  }

  // ─── files.write ───────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeWrite(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_write')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'files.write',
        error: 'Files module is disabled or write not allowed.',
      );
    }
    try {
      final path = (args['path'] as String? ?? '').trim();
      final content = args['content'] as String? ?? '';
      final append = args['append'] as bool? ?? false;

      if (path.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.write',
          error: 'path is required.',
        );
      }

      final resolved = await _resolveSafePath(path);
      if (resolved == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.write',
          error: 'Invalid path: cannot escape workspace.',
        );
      }

      final file = File(resolved);
      await file.parent.create(recursive: true);

      if (append) {
        await file.writeAsString(content, mode: FileMode.append);
      } else {
        await file.writeAsString(content);
      }

      return ToolExecutionResult(
        success: true,
        toolName: 'files.write',
        data: {'written': true, 'path': path, 'append': append},
        actions: [
          ResultAction(
            label: 'Open File Manager',
            labelId: 'Buka File Manager',
            icon: 'folder_open_rounded',
            type: 'open_folder',
            target: agentName,
          ),
        ],
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'files.write',
        error: e.toString(),
      );
    }
  }

  // ─── files.delete ──────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeDelete(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_delete')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'files.delete',
        error: 'Files module is disabled or delete not allowed.',
      );
    }
    try {
      final path = (args['path'] as String? ?? '').trim();
      if (path.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.delete',
          error: 'path is required.',
        );
      }

      final resolved = await _resolveSafePath(path);
      if (resolved == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.delete',
          error: 'Invalid path: cannot escape workspace.',
        );
      }

      final file = File(resolved);
      final dir = Directory(resolved);

      if (await file.exists()) {
        await file.delete();
      } else if (await dir.exists()) {
        await dir.delete(recursive: true);
      } else {
        return ToolExecutionResult(
          success: false,
          toolName: 'files.delete',
          error: 'Not found: $path',
        );
      }

      return ToolExecutionResult(
        success: true,
        toolName: 'files.delete',
        data: {'deleted': true, 'path': path},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'files.delete',
        error: e.toString(),
      );
    }
  }

  // ─── files.list ────────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeList(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'files.list',
        error: 'Files module is disabled or read not allowed.',
      );
    }
    try {
      final path = (args['path'] as String? ?? '').trim();

      // Empty path = workspace root.
      final resolved = path.isEmpty
          ? (await WorkspacePaths.getAgentWorkspace(agentName)).path
          : await _resolveSafePath(path);

      if (resolved == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.list',
          error: 'Invalid path: cannot escape workspace.',
        );
      }

      final dir = Directory(resolved);
      if (!await dir.exists()) {
        return ToolExecutionResult(
          success: false,
          toolName: 'files.list',
          error: 'Directory not found: $path',
        );
      }

      final entries = <Map<String, dynamic>>[];
      await for (final entity in dir.list()) {
        final name = entity.path.split(Platform.pathSeparator).last;
        final isDir = entity is Directory;
        final stat = await entity.stat();
        entries.add({
          'name': name,
          'type': isDir ? 'directory' : 'file',
          'size': stat.size,
          'modified': stat.modified.toIso8601String(),
        });
      }

      // Sort: directories first, then alphabetical.
      entries.sort((a, b) {
        if (a['type'] != b['type']) {
          return a['type'] == 'directory' ? -1 : 1;
        }
        return (a['name'] as String).compareTo(b['name'] as String);
      });

      return ToolExecutionResult(
        success: true,
        toolName: 'files.list',
        data: {
          'path': path.isEmpty ? '/' : path,
          'entries': entries,
          'count': entries.length,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'files.list',
        error: e.toString(),
      );
    }
  }

  // ─── files.move ────────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeMove(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_organize')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'files.move',
        error: 'Files module is disabled or organize not allowed.',
      );
    }
    try {
      final from = (args['from'] as String? ?? '').trim();
      final to = (args['to'] as String? ?? '').trim();

      if (from.isEmpty || to.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.move',
          error: 'Both "from" and "to" paths are required.',
        );
      }

      final resolvedFrom = await _resolveSafePath(from);
      final resolvedTo = await _resolveSafePath(to);

      if (resolvedFrom == null || resolvedTo == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.move',
          error: 'Invalid path: cannot escape workspace.',
        );
      }

      final source = File(resolvedFrom);
      if (!await source.exists()) {
        // Try as directory.
        final sourceDir = Directory(resolvedFrom);
        if (!await sourceDir.exists()) {
          return ToolExecutionResult(
            success: false,
            toolName: 'files.move',
            error: 'Source not found: $from',
          );
        }
        await sourceDir.rename(resolvedTo);
      } else {
        // Ensure target parent exists.
        await File(resolvedTo).parent.create(recursive: true);
        await source.rename(resolvedTo);
      }

      return ToolExecutionResult(
        success: true,
        toolName: 'files.move',
        data: {'moved': true, 'from': from, 'to': to},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'files.move',
        error: e.toString(),
      );
    }
  }

  // ─── files.mkdir ───────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeMkdir(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_create')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'files.mkdir',
        error: 'Files module is disabled or create not allowed.',
      );
    }
    try {
      final path = (args['path'] as String? ?? '').trim();
      if (path.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.mkdir',
          error: 'path is required.',
        );
      }

      final resolved = await _resolveSafePath(path);
      if (resolved == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.mkdir',
          error: 'Invalid path: cannot escape workspace.',
        );
      }

      final dir = Directory(resolved);
      await dir.create(recursive: true);

      return ToolExecutionResult(
        success: true,
        toolName: 'files.mkdir',
        data: {'created': true, 'path': path},
        actions: [
          ResultAction(
            label: 'Open File Manager',
            labelId: 'Buka File Manager',
            icon: 'folder_open_rounded',
            type: 'open_folder',
            target: agentName,
          ),
        ],
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'files.mkdir',
        error: e.toString(),
      );
    }
  }
}

/// Internal: resolved-path bundle so file ops can report cross-workspace
/// landings to the runtime without re-resolving.
class _ResolvedPath {
  const _ResolvedPath(this.path, this.isOutsideOwnWorkspace);
  final String path;
  final bool isOutsideOwnWorkspace;
}
