import '../../../services/agent_runtime/runtime_models.dart';
import '../../../services/workspace/workspace_file_service.dart';
import '../data/module_repository.dart';
import 'notes_models.dart';
import 'notes_repository.dart';

/// Executes notes-related tool calls.
class NotesTools {
  NotesTools({NotesRepository? repository, ModuleRepository? moduleRepository})
    : _repo = repository ?? NotesRepository(),
      _moduleRepository = moduleRepository ?? ModuleRepository();

  final NotesRepository _repo;
  final ModuleRepository _moduleRepository;

  /// Check if the notes module is enabled and a specific setting is allowed.
  Future<bool> _isAllowed(String settingKey) async {
    final modules = await _moduleRepository.getInstalled();
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
      final content = _contentFromArgs(args);
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
      final persisted = await _repo.getNote(note.id);
      final verifiedFields = _verifiedNoteFields(persisted, {
        'title': title,
        'content': content,
        'source': source,
        if (tags.isNotEmpty) 'tags': tags,
      });
      return ToolExecutionResult(
        success: true,
        toolName: 'notes.create',
        data: {
          'noteId': note.id,
          'created': true,
          'persisted': persisted != null,
          'verifiedFields': verifiedFields,
          'title': persisted?.title ?? note.title,
          'content': persisted?.content ?? note.content,
        },
        actions: const [
          ResultAction(
            label: 'Open Notes',
            icon: 'note_outlined',
            type: 'navigate',
            target: '/notes',
          ),
        ],
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notes.create',
        error: e.toString(),
      );
    }
  }

  String _contentFromArgs(Map<String, dynamic> args) {
    for (final key in const ['content', 'body', 'message', 'text']) {
      final value = args[key]?.toString().trim() ?? '';
      if (value.isNotEmpty && value != '...' && value != '…') return value;
    }
    return '';
  }

  Future<ToolExecutionResult> executeListRecent(
    Map<String, dynamic> args,
  ) async {
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
              .map(
                (n) => {
                  'id': n.id,
                  'title': n.title,
                  'pinned': n.pinned,
                  'updatedAt': n.updatedAt.millisecondsSinceEpoch,
                },
              )
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
              .map(
                (n) => {
                  'id': n.id,
                  'title': n.title,
                  'updatedAt': n.updatedAt.millisecondsSinceEpoch,
                },
              )
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
      final expected = <String, Object?>{};
      if (title != null) expected['title'] = title;
      if (content != null) expected['content'] = content;
      if (tags != null) expected['tags'] = tags;
      if (expected.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notes.update',
          error: 'At least one field must be provided.',
        );
      }
      final updated = await _repo.updateNote(
        noteId,
        title: title,
        content: content,
        tags: tags,
      );
      final persisted = await _repo.getNote(updated.id);
      final verifiedFields = _verifiedNoteFields(persisted, expected);
      return ToolExecutionResult(
        success: true,
        toolName: 'notes.update',
        data: {
          'updated': true,
          'noteId': updated.id,
          'persisted': persisted != null,
          'verifiedFields': verifiedFields == expected.length
              ? verifiedFields
              : 0,
          'title': persisted?.title ?? updated.title,
          'content': persisted?.content ?? updated.content,
        },
        actions: const [
          ResultAction(
            label: 'Open Notes',
            icon: 'note_outlined',
            type: 'navigate',
            target: '/notes',
          ),
        ],
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notes.update',
        error: e.toString(),
      );
    }
  }

  /// Toggle pinned state on a note. Used by notes.pin and notes.unpin.
  Future<ToolExecutionResult> executeSetPinned(
    Map<String, dynamic> args, {
    required bool pinned,
  }) async {
    final toolName = pinned ? 'notes.pin' : 'notes.unpin';
    if (!await _isAllowed('allow_create')) {
      return ToolExecutionResult(
        success: false,
        toolName: toolName,
        error: 'Notes module is disabled or write not allowed.',
      );
    }
    try {
      final noteId = (args['noteId'] as String? ?? '').trim();
      if (noteId.isEmpty) {
        return ToolExecutionResult(
          success: false,
          toolName: toolName,
          error: 'noteId is required.',
        );
      }
      final updated = await _repo.updateNote(noteId, pinned: pinned);
      final persisted = await _repo.getNote(updated.id);
      return ToolExecutionResult(
        success: true,
        toolName: toolName,
        data: {
          'updated': true,
          'noteId': updated.id,
          'pinned': persisted?.pinned ?? updated.pinned,
          'stateVerified': persisted?.pinned == pinned,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: toolName,
        error: e.toString(),
      );
    }
  }

  /// Toggle archived state on a note.
  Future<ToolExecutionResult> executeSetArchived(
    Map<String, dynamic> args, {
    required bool archived,
  }) async {
    final toolName = archived ? 'notes.archive' : 'notes.unarchive';
    if (!await _isAllowed('allow_create')) {
      return ToolExecutionResult(
        success: false,
        toolName: toolName,
        error: 'Notes module is disabled or write not allowed.',
      );
    }
    try {
      final noteId = (args['noteId'] as String? ?? '').trim();
      if (noteId.isEmpty) {
        return ToolExecutionResult(
          success: false,
          toolName: toolName,
          error: 'noteId is required.',
        );
      }
      final updated = await _repo.updateNote(noteId, archived: archived);
      final persisted = await _repo.getNote(updated.id);
      return ToolExecutionResult(
        success: true,
        toolName: toolName,
        data: {
          'updated': true,
          'noteId': updated.id,
          'archived': persisted?.archived ?? updated.archived,
          'stateVerified': persisted?.archived == archived,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: toolName,
        error: e.toString(),
      );
    }
  }

  /// Append content to an existing note (with newline separator).
  /// Useful for daily journals, running logs.
  Future<ToolExecutionResult> executeAppend(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_create')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'notes.append',
        error: 'Notes module is disabled or write not allowed.',
      );
    }
    try {
      final noteId = (args['noteId'] as String? ?? '').trim();
      final content = (args['content'] as String? ?? '');
      if (noteId.isEmpty || content.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notes.append',
          error: 'noteId and content are required.',
        );
      }
      final existing = await _repo.getNote(noteId);
      if (existing == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notes.append',
          error: 'Note not found: $noteId',
        );
      }
      final separator = (args['separator'] as String?) ?? '\n\n';
      final newContent = existing.content + separator + content;
      final updated = await _repo.updateNote(noteId, content: newContent);
      final persisted = await _repo.getNote(updated.id);
      return ToolExecutionResult(
        success: true,
        toolName: 'notes.append',
        data: {
          'updated': true,
          'noteId': updated.id,
          'totalLength': persisted?.content.length ?? updated.content.length,
          'stateVerified': persisted?.content == newContent,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notes.append',
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
      final deleted = await _repo.deleteNote(noteId);
      if (deleted <= 0) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notes.delete',
          error: 'Note not found: $noteId',
        );
      }
      final persisted = await _repo.getNote(noteId);
      return ToolExecutionResult(
        success: true,
        toolName: 'notes.delete',
        data: {
          'deleted': deleted,
          'noteId': noteId,
          'absent': persisted == null,
        },
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
          : (await Future.wait(
              noteIds.map(_repo.getNote),
            )).whereType<dynamic>().toList();

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
        actions: [
          ResultAction(
            label: 'Open File Manager',
            icon: 'folder_open_rounded',
            type: 'open_folder',
            target: agentName,
            params: {'subfolder': 'notes'},
          ),
        ],
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notes.export',
        error: e.toString(),
      );
    }
  }

  int _verifiedNoteFields(Note? note, Map<String, Object?> expected) {
    if (note == null || expected.isEmpty) return 0;
    var verified = 0;
    for (final entry in expected.entries) {
      if (_valuesMatch(_noteValue(note, entry.key), entry.value)) verified++;
    }
    return verified == expected.length ? verified : 0;
  }

  bool _valuesMatch(Object? actual, Object? expected) {
    if (actual == expected) return true;
    if (actual is List && expected is List) {
      if (actual.length != expected.length) return false;
      for (var i = 0; i < actual.length; i++) {
        if (actual[i] != expected[i]) return false;
      }
      return true;
    }
    return false;
  }

  Object? _noteValue(Note note, String key) {
    switch (key) {
      case 'title':
        return note.title;
      case 'content':
        return note.content;
      case 'tags':
        return note.tags;
      case 'source':
        return note.source;
      default:
        return null;
    }
  }
}
