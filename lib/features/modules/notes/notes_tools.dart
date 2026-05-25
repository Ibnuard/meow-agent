import '../../../services/agent_runtime/runtime_models.dart';
import '../../../services/workspace/workspace_file_service.dart';
import '../data/module_repository.dart';
import 'notes_repository.dart';

/// Executes notes-related tool calls.
class NotesTools {
  NotesTools({NotesRepository? repository})
      : _repo = repository ?? NotesRepository();

  final NotesRepository _repo;

  /// Check if the notes module is enabled and a specific setting is allowed.
  Future<bool> _isAllowed(String settingKey) async {
    final moduleRepo = ModuleRepository();
    final modules = await moduleRepo.getInstalled();
    final notesMod = modules.where((m) => m.id == 'notes').firstOrNull;
    if (notesMod == null || !notesMod.enabled) return false;
    return notesMod.settings[settingKey] ?? true;
  }

  Future<ToolExecutionResult> executeCreate(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_create')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'notes.create',
        error: 'Notes module is disabled or create not allowed.',
      );
    }
    try {
      final title = (args['title'] as String? ?? '').trim();
      final content = (args['content'] as String? ?? '').trim();
      if (title.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notes.create',
          error: 'Title is required.',
        );
      }
      final tags = (args['tags'] as List?)?.cast<String>() ?? [];
      final source = args['source'] as String? ?? 'agent';
      final note = await _repo.createNote(
        title: title,
        content: content,
        tags: tags,
        source: source,
      );
      return ToolExecutionResult(
        success: true,
        toolName: 'notes.create',
        data: {'noteId': note.id, 'created': true},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notes.create',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeListRecent(
      Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'notes.list_recent',
        error: 'Notes module is disabled or read not allowed.',
      );
    }
    try {
      final limit = (args['limit'] as num?)?.toInt() ?? 10;
      final notes = await _repo.listRecentNotes(limit: limit);
      return ToolExecutionResult(
        success: true,
        toolName: 'notes.list_recent',
        data: {
          'notes': notes
              .map((n) => {
                    'id': n.id,
                    'title': n.title,
                    'pinned': n.pinned,
                    'updatedAt': n.updatedAt.millisecondsSinceEpoch,
                  })
              .toList(),
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notes.list_recent',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeRead(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'notes.read',
        error: 'Notes module is disabled or read not allowed.',
      );
    }
    try {
      final noteId = args['noteId'] as String? ?? '';
      if (noteId.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notes.read',
          error: 'noteId is required.',
        );
      }
      final note = await _repo.getNote(noteId);
      if (note == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notes.read',
          error: 'Note not found: $noteId',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'notes.read',
        data: {
          'note': {
            'id': note.id,
            'title': note.title,
            'content': note.content,
            'tags': note.tags,
            'pinned': note.pinned,
            'createdAt': note.createdAt.millisecondsSinceEpoch,
            'updatedAt': note.updatedAt.millisecondsSinceEpoch,
          },
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notes.read',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeSearch(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_search')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'notes.search',
        error: 'Notes module is disabled or search not allowed.',
      );
    }
    try {
      final query = (args['query'] as String? ?? '').trim();
      if (query.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notes.search',
          error: 'Search query is required.',
        );
      }
      final results = await _repo.searchNotes(query);
      return ToolExecutionResult(
        success: true,
        toolName: 'notes.search',
        data: {
          'results': results
              .map((n) => {
                    'id': n.id,
                    'title': n.title,
                    'updatedAt': n.updatedAt.millisecondsSinceEpoch,
                  })
              .toList(),
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notes.search',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeUpdate(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_create')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'notes.update',
        error: 'Notes module is disabled or write not allowed.',
      );
    }
    try {
      final noteId = args['noteId'] as String? ?? '';
      if (noteId.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notes.update',
          error: 'noteId is required.',
        );
      }
      final title = args['title'] as String?;
      final content = args['content'] as String?;
      final tags = (args['tags'] as List?)?.cast<String>();
      await _repo.updateNote(noteId, title: title, content: content, tags: tags);
      return const ToolExecutionResult(
        success: true,
        toolName: 'notes.update',
        data: {'updated': true},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notes.update',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeDelete(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_create')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'notes.delete',
        error: 'Notes module is disabled or write not allowed.',
      );
    }
    try {
      final noteId = args['noteId'] as String? ?? '';
      if (noteId.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notes.delete',
          error: 'noteId is required.',
        );
      }
      await _repo.deleteNote(noteId);
      return const ToolExecutionResult(
        success: true,
        toolName: 'notes.delete',
        data: {'deleted': true},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notes.delete',
        error: e.toString(),
      );
    }
  }
  Future<ToolExecutionResult> executeExport(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_export')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'notes.export',
        error: 'Notes module is disabled or export not allowed.',
      );
    }
    try {
      final agentName = (args['agentName'] as String? ?? '').trim();
      if (agentName.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notes.export',
          error: 'agentName is required.',
        );
      }

      final noteIdsRaw = args['noteIds'];
      final noteIds = noteIdsRaw is List
          ? noteIdsRaw.map((e) => e.toString()).toList()
          : <String>[];

      // Empty noteIds → export all notes.
      final notes = noteIds.isEmpty
          ? await _repo.listRecentNotes(limit: 1000)
          : (await Future.wait(noteIds.map(_repo.getNote)))
              .whereType<dynamic>()
              .toList();

      if (notes.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notes.export',
          error: 'No notes to export.',
        );
      }

      final exported = <String>[];
      for (final note in notes) {
        if (note == null) continue;
        await WorkspaceFileService.exportNote(
          agentName,
          title: note.title,
          content: note.content,
          tags: note.tags,
        );
        exported.add(note.title);
      }

      return ToolExecutionResult(
        success: true,
        toolName: 'notes.export',
        data: {
          'exported': exported.length,
          'titles': exported,
          'destination': 'Documents/MeowAgent/Agents/$agentName/notes/',
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notes.export',
        error: e.toString(),
      );
    }
  }
}
