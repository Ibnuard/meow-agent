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

  // ─── files.copy ────────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeCopy(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_organize')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'files.copy',
        error: 'Files module is disabled or organize not allowed.',
      );
    }
    try {
      final from = (args['from'] as String? ?? '').trim();
      final to = (args['to'] as String? ?? '').trim();
      if (from.isEmpty || to.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.copy',
          error: 'Both "from" and "to" paths are required.',
        );
      }
      final resolvedFrom = await _resolveSafePath(from);
      final resolvedTo = await _resolveSafePath(to);
      if (resolvedFrom == null || resolvedTo == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.copy',
          error: 'Invalid path: cannot escape workspace.',
        );
      }
      final source = File(resolvedFrom);
      if (await source.exists()) {
        await File(resolvedTo).parent.create(recursive: true);
        await source.copy(resolvedTo);
      } else {
        final dir = Directory(resolvedFrom);
        if (!await dir.exists()) {
          return ToolExecutionResult(
            success: false,
            toolName: 'files.copy',
            error: 'Source not found: $from',
          );
        }
        await _copyDirectory(dir, Directory(resolvedTo));
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'files.copy',
        data: {'copied': true, 'from': from, 'to': to},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'files.copy',
        error: e.toString(),
      );
    }
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(recursive: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (entity is Directory) {
        await _copyDirectory(entity, Directory('${target.path}/$name'));
      } else if (entity is File) {
        await entity.copy('${target.path}/$name');
      }
    }
  }

  // ─── files.append ──────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeAppend(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_write')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'files.append',
        error: 'Files module is disabled or write not allowed.',
      );
    }
    try {
      final path = (args['path'] as String? ?? '').trim();
      final content = args['content'] as String? ?? '';
      if (path.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.append',
          error: 'path is required.',
        );
      }
      final resolved = await _resolveSafePath(path);
      if (resolved == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.append',
          error: 'Invalid path: cannot escape workspace.',
        );
      }
      final file = File(resolved);
      await file.parent.create(recursive: true);
      // Add a trailing newline if file exists and doesn't end with one.
      if (await file.exists()) {
        final existing = await file.readAsString();
        if (existing.isNotEmpty && !existing.endsWith('\n')) {
          await file.writeAsString('\n', mode: FileMode.append);
        }
      }
      await file.writeAsString(content, mode: FileMode.append);
      final stat = await file.stat();
      return ToolExecutionResult(
        success: true,
        toolName: 'files.append',
        data: {'path': path, 'size': stat.size},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'files.append',
        error: e.toString(),
      );
    }
  }

  // ─── files.metadata ────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeMetadata(
    Map<String, dynamic> args,
  ) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'files.metadata',
        error: 'Files module is disabled or read not allowed.',
      );
    }
    try {
      final path = (args['path'] as String? ?? '').trim();
      if (path.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.metadata',
          error: 'path is required.',
        );
      }
      final resolved = await _resolveSafePath(path);
      if (resolved == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.metadata',
          error: 'Invalid path.',
        );
      }
      final entityType = await FileSystemEntity.type(resolved);
      if (entityType == FileSystemEntityType.notFound) {
        return ToolExecutionResult(
          success: false,
          toolName: 'files.metadata',
          error: 'Not found: $path',
        );
      }
      final stat = await FileStat.stat(resolved);
      final isDir = entityType == FileSystemEntityType.directory;
      final ext = path.contains('.')
          ? path.split('.').last.toLowerCase()
          : '';
      String? mime;
      int? lineCount;
      if (!isDir) {
        mime = _mimeFor(ext);
        // Cheap line count for small text files only.
        if (stat.size < 256 * 1024 && _isTextual(ext)) {
          try {
            final content = await File(resolved).readAsString();
            lineCount = '\n'.allMatches(content).length + 1;
          } catch (_) {
            // Binary or encoding mismatch — leave null.
          }
        }
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'files.metadata',
        data: {
          'path': path,
          'type': isDir ? 'directory' : 'file',
          'size': stat.size,
          'modified': stat.modified.toIso8601String(),
          'created': stat.changed.toIso8601String(),
          if (ext.isNotEmpty) 'extension': ext,
          'mime': ?mime,
          'lineCount': ?lineCount,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'files.metadata',
        error: e.toString(),
      );
    }
  }

  // ─── files.search ──────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeSearch(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'files.search',
        error: 'Files module is disabled or read not allowed.',
      );
    }
    try {
      final query = (args['query'] as String? ?? '').trim();
      final namePattern = (args['namePattern'] as String? ?? '').trim();
      if (query.isEmpty && namePattern.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'files.search',
          error: 'Either query or namePattern is required.',
        );
      }
      final rawRoot = (args['root'] as String? ?? '').trim();
      final maxResults =
          (args['maxResults'] as num?)?.toInt().clamp(1, 200) ?? 50;
      final wantsOwnWorkspace =
          rawRoot.isEmpty || _isOwnWorkspaceShortcut(rawRoot);
      String? resolvedRoot;
      String? fallbackNote;
      if (wantsOwnWorkspace) {
        resolvedRoot =
            (await WorkspacePaths.getAgentWorkspace(agentName)).path;
      } else {
        resolvedRoot = await _resolveSafePath(rawRoot);
        if (resolvedRoot == null || !await Directory(resolvedRoot).exists()) {
          // Read-only fallback to own workspace so the search still produces
          // useful output when the LLM passes a stale or absolute path.
          resolvedRoot =
              (await WorkspacePaths.getAgentWorkspace(agentName)).path;
          fallbackNote =
              'Path "$rawRoot" not found inside MeowAgent root; searched current agent workspace instead.';
        }
      }
      final dir = Directory(resolvedRoot);
      if (!await dir.exists()) {
        return ToolExecutionResult(
          success: false,
          toolName: 'files.search',
          error: 'Workspace directory does not exist: $resolvedRoot',
        );
      }
      // Compile glob → regex.
      final nameRe = namePattern.isEmpty
          ? null
          : RegExp(
              '^${RegExp.escape(namePattern).replaceAll(r'\*', '.*').replaceAll(r'\?', '.')}\$',
              caseSensitive: false,
            );
      final results = <Map<String, dynamic>>[];
      final lowerQuery = query.toLowerCase();
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (results.length >= maxResults) break;
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (nameRe != null && !nameRe.hasMatch(name)) continue;
        var matched = query.isEmpty;
        String? snippet;
        if (query.isNotEmpty) {
          final stat = await entity.stat();
          if (stat.size > 1024 * 1024) continue; // Skip large files.
          try {
            final content = await entity.readAsString();
            final lower = content.toLowerCase();
            final idx = lower.indexOf(lowerQuery);
            if (idx >= 0) {
              matched = true;
              final start = (idx - 30).clamp(0, content.length);
              final end = (idx + query.length + 30).clamp(0, content.length);
              snippet = content.substring(start, end).replaceAll('\n', ' ');
            }
          } catch (_) {
            // Binary file — skip.
            continue;
          }
        }
        if (!matched) continue;
        final wsRoot = (await WorkspacePaths.getMeowRoot()).path;
        final relPath = entity.path.startsWith(wsRoot)
            ? entity.path.substring(wsRoot.length + 1)
            : entity.path;
        results.add({
          'path': relPath.replaceAll(Platform.pathSeparator, '/'),
          'name': name,
          'snippet': ?snippet,
        });
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'files.search',
        data: {
          'count': results.length,
          'results': results,
          'truncated': results.length >= maxResults,
          'note': ?fallbackNote,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'files.search',
        error: e.toString(),
      );
    }
  }

  // ─── files.tree ────────────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeTree(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'files.tree',
        error: 'Files module is disabled or read not allowed.',
      );
    }
    try {
      final rawRoot = (args['root'] as String? ?? '').trim();
      final maxDepth = (args['maxDepth'] as num?)?.toInt().clamp(1, 8) ?? 3;
      final wantsOwnWorkspace =
          rawRoot.isEmpty || _isOwnWorkspaceShortcut(rawRoot);
      String? resolvedRoot;
      String? fallbackNote;
      String displayedRoot = rawRoot.isEmpty ? '.' : rawRoot;
      if (wantsOwnWorkspace) {
        resolvedRoot =
            (await WorkspacePaths.getAgentWorkspace(agentName)).path;
        displayedRoot = '.';
      } else {
        resolvedRoot = await _resolveSafePath(rawRoot);
        if (resolvedRoot == null || !await Directory(resolvedRoot).exists()) {
          // Read-only graceful fallback: agent likely passed an absolute or
          // misformatted path from system.self / earlier tool output.
          // Show the agent's own workspace so the user gets useful context
          // instead of a hard failure.
          resolvedRoot =
              (await WorkspacePaths.getAgentWorkspace(agentName)).path;
          fallbackNote =
              'Path "$rawRoot" not found inside MeowAgent root; falling back to current agent workspace.';
          displayedRoot = '.';
        }
      }
      final dir = Directory(resolvedRoot);
      if (!await dir.exists()) {
        return ToolExecutionResult(
          success: false,
          toolName: 'files.tree',
          error: 'Workspace directory does not exist: $resolvedRoot',
        );
      }
      final buf = StringBuffer()..writeln(displayedRoot);
      await _writeTree(dir, buf, '', maxDepth, 0);
      return ToolExecutionResult(
        success: true,
        toolName: 'files.tree',
        data: {
          'tree': buf.toString().trimRight(),
          'root': displayedRoot,
          'note': ?fallbackNote,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'files.tree',
        error: e.toString(),
      );
    }
  }

  /// True when caller's `root` is a common shortcut meaning "own workspace".
  /// LLMs sometimes pass these instead of leaving root empty.
  bool _isOwnWorkspaceShortcut(String root) {
    final r = root.toLowerCase().replaceAll('\\', '/');
    return r == '.' ||
        r == './' ||
        r == '/' ||
        r == 'workspace' ||
        r == 'workspace/' ||
        r == 'current' ||
        r == 'agen ini' ||
        r == 'agent ini' ||
        r == 'this agent' ||
        r == 'own' ||
        r == 'self';
  }


  Future<void> _writeTree(
    Directory dir,
    StringBuffer buf,
    String prefix,
    int maxDepth,
    int depth,
  ) async {
    if (depth >= maxDepth) return;
    final entries = await dir.list().toList();
    entries.sort((a, b) {
      final aIsDir = a is Directory;
      final bIsDir = b is Directory;
      if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
      return a.path.compareTo(b.path);
    });
    for (var i = 0; i < entries.length; i++) {
      final isLast = i == entries.length - 1;
      final entity = entries[i];
      final name = entity.path.split(Platform.pathSeparator).last;
      final connector = isLast ? '└── ' : '├── ';
      final suffix = entity is Directory ? '/' : '';
      buf.writeln('$prefix$connector$name$suffix');
      if (entity is Directory) {
        final newPrefix = prefix + (isLast ? '    ' : '│   ');
        await _writeTree(entity, buf, newPrefix, maxDepth, depth + 1);
      }
    }
  }

  // ─── helpers ───────────────────────────────────────────────────────────────

  static const Set<String> _textualExt = {
    'md', 'txt', 'json', 'yaml', 'yml', 'csv', 'tsv', 'log',
    'dart', 'js', 'ts', 'py', 'java', 'kt', 'rb', 'go', 'rs',
    'html', 'css', 'xml', 'sh', 'bat', 'env', 'ini', 'toml', 'conf',
  };

  bool _isTextual(String ext) => _textualExt.contains(ext);

  String? _mimeFor(String ext) {
    return switch (ext) {
      'md' || 'markdown' => 'text/markdown',
      'txt' || 'log' => 'text/plain',
      'json' => 'application/json',
      'yaml' || 'yml' => 'text/yaml',
      'csv' => 'text/csv',
      'html' || 'htm' => 'text/html',
      'css' => 'text/css',
      'js' => 'text/javascript',
      'ts' => 'text/typescript',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'pdf' => 'application/pdf',
      'zip' => 'application/zip',
      'mp3' => 'audio/mpeg',
      'mp4' => 'video/mp4',
      _ => null,
    };
  }
}

/// Internal: resolved-path bundle so file ops can report cross-workspace
/// landings to the runtime without re-resolving.
class _ResolvedPath {
  const _ResolvedPath(this.path, this.isOutsideOwnWorkspace);
  final String path;
  final bool isOutsideOwnWorkspace;
}
