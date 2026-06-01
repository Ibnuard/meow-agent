import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../../services/workspace/workspace_file_service.dart';
import '../../agents/data/agent_repository.dart';
import '../../settings/data/app_language_provider.dart';
import 'notes_models.dart';
import 'notes_repository.dart';

/// Provider for the notes repository.
final notesRepositoryProvider = Provider((_) => NotesRepository());

/// Provider for the notes list — autoDispose ensures refetch on screen mount.
final notesListProvider = FutureProvider.autoDispose<List<Note>>((ref) async {
  final repo = ref.watch(notesRepositoryProvider);
  return repo.listRecentNotes(limit: 50);
});

/// Notes list screen — shows recent notes with search.
class NotesListScreen extends ConsumerStatefulWidget {
  const NotesListScreen({super.key});

  @override
  ConsumerState<NotesListScreen> createState() => _NotesListScreenState();
}

class _NotesListScreenState extends ConsumerState<NotesListScreen> {
  final _searchController = TextEditingController();
  List<Note>? _searchResults;
  bool _searching = false;

  // Selection mode state.
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.invalidate(notesListProvider));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = null;
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    final repo = ref.read(notesRepositoryProvider);
    final results = await repo.searchNotes(query);
    if (mounted) {
      setState(() {
        _searchResults = results;
        _searching = false;
      });
    }
  }

  void _toggleSelection() {
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) _selectedIds.clear();
    });
  }

  void _toggleNoteSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Future<void> _exportSelected() async {
    if (_selectedIds.isEmpty) return;

    final langPref = ref.read(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    final agents = ref.read(agentListProvider);
    if (agents.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.notesExportNoAgent)),
        );
      }
      return;
    }

    // If multiple agents, ask which workspace.
    String? agentName;
    if (agents.length == 1) {
      agentName = agents.first.name;
    } else {
      agentName = await _pickAgent(agents.map((a) => a.name).toList(), s);
      if (agentName == null) return;
    }

    final repo = ref.read(notesRepositoryProvider);
    int exported = 0;
    for (final id in _selectedIds) {
      final note = await repo.getNote(id);
      if (note == null) continue;
      await WorkspaceFileService.exportNote(
        agentName,
        title: note.title,
        content: note.content,
        tags: note.tags,
      );
      exported++;
    }

    if (mounted) {
      setState(() {
        _selectionMode = false;
        _selectedIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.notesExportedCount(exported, agentName)),
        ),
      );
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;

    final langPref = ref.read(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    final confirmed = await showMeowConfirmDialog(
      context,
      isId: s.isId,
      title: s.notesDeleteTitle,
      message: s.notesDeleteMessage(_selectedIds.length),
    );
    if (!confirmed) return;

    final repo = ref.read(notesRepositoryProvider);
    final count = _selectedIds.length;
    for (final id in _selectedIds) {
      await repo.deleteNote(id);
    }
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
    ref.invalidate(notesListProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(s.notesDeletedCount(count)),
      ),
    );
  }

  Future<String?> _pickAgent(List<String> names, AppStrings s) async {
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(s.notesExportTitle),
        children: names
            .map((n) => SimpleDialogOption(
                  child: Text(n),
                  onPressed: () => Navigator.pop(ctx, n),
                ))
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final notesAsync = ref.watch(notesListProvider);
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectionMode
            ? s.notesSelectedCount(_selectedIds.length)
            : s.notesTitle),
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: _toggleSelection,
              )
            : null,
        actions: [
          if (_selectionMode) ...[
            IconButton(
              icon: const Icon(Icons.ios_share_rounded),
              tooltip: s.notesExportToWorkspace,
              onPressed: _selectedIds.isEmpty ? null : _exportSelected,
            ),
            IconButton(
              icon: Icon(Icons.delete_outline_rounded, color: cs.error),
              tooltip: s.delete,
              onPressed:
                  _selectedIds.isEmpty ? null : _deleteSelected,
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.checklist_rounded),
              tooltip: s.notesSelectMultiple,
              onPressed: _toggleSelection,
            ),
            IconButton(
              icon: const Icon(Icons.add_rounded),
              tooltip: s.notesNewNote,
              onPressed: () async {
                await context.push('/notes/new');
                ref.invalidate(notesListProvider);
              },
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Search bar.
            if (!_selectionMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Container(
                  decoration: BoxDecoration(
                    color: extras.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: extras.subtleBorder),
                  ),
                  child: TextField(
                    controller: _searchController,
                    onChanged: _search,
                    style: TextStyle(fontSize: 14, color: cs.onSurface),
                    decoration: InputDecoration(
                      hintText: s.notesSearch,
                      hintStyle: TextStyle(
                        fontSize: 14,
                        color: cs.onSurfaceVariant,
                      ),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        size: 20,
                        color: cs.onSurfaceVariant,
                      ),
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
              ),

            // Selection mode banner.
            if (_selectionMode)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded, size: 16, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s.notesSelectHint,
                        style: TextStyle(fontSize: 12, color: cs.primary),
                      ),
                    ),
                  ],
                ),
              ),

            // Notes list.
            Expanded(
              child: _searching
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : _searchResults != null
                      ? _buildNotesList(_searchResults!, cs, extras, s)
                      : notesAsync.when(
                          loading: () => const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          error: (e, _) => Center(child: Text('Error: $e')),
                          data: (notes) =>
                              _buildNotesList(notes, cs, extras, s),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotesList(
    List<Note> notes,
    ColorScheme cs,
    MeowExtras extras,
    AppStrings s,
  ) {
    if (notes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.note_outlined,
                size: 44,
                color: cs.onSurfaceVariant.withValues(alpha: 0.6),
              ),
              const SizedBox(height: 12),
              Text(
                _searchResults != null
                    ? s.notesNoResults
                    : s.notesEmpty,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _searchResults != null
                    ? s.notesEmptyTryKeyword
                    : s.notesEmptyCreateFirst,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
      itemCount: notes.length,
      itemBuilder: (context, i) {
        final note = notes[i];
        final selected = _selectedIds.contains(note.id);
        return _NoteCard(
          note: note,
          selectionMode: _selectionMode,
          selected: selected,
          onTap: () async {
            if (_selectionMode) {
              _toggleNoteSelection(note.id);
            } else {
              await context.push('/notes/${note.id}');
              ref.invalidate(notesListProvider);
            }
          },
          onLongPress: () {
            if (!_selectionMode) {
              setState(() {
                _selectionMode = true;
                _selectedIds.add(note.id);
              });
            }
          },
        );
      },
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.note,
    required this.onTap,
    required this.onLongPress,
    required this.selectionMode,
    required this.selected,
  });
  final Note note;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final timeAgo = _formatTimeAgo(note.updatedAt);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected
            ? cs.primary.withValues(alpha: 0.08)
            : extras.card,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected
                    ? cs.primary.withValues(alpha: 0.4)
                    : extras.subtleBorder,
                width: selected ? 1.2 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (selectionMode) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 12),
                    child: Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 22,
                      color: selected
                          ? cs.primary
                          : cs.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                  ),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (note.pinned)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Icon(
                                Icons.push_pin_rounded,
                                size: 14,
                                color: cs.primary,
                              ),
                            ),
                          Expanded(
                            child: Text(
                              note.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface,
                              ),
                            ),
                          ),
                          Text(
                            timeAgo,
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      if (note.content.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          note.content
                              .replaceAll(RegExp(r'[#*\-_>`]'), '')
                              .trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                            height: 1.3,
                          ),
                        ),
                      ],
                      if (note.tags.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          children: note.tags
                              .take(3)
                              .map((tag) => Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color:
                                          cs.primary.withValues(alpha: 0.1),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      tag,
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: cs.primary,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ))
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${dt.day}/${dt.month}';
  }
}