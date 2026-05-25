import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
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

  @override
  void initState() {
    super.initState();
    // Force refresh on every screen entry (covers agent-created notes).
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

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final notesAsync = ref.watch(notesListProvider);
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: s.isId ? 'Buat Note' : 'New Note',
            onPressed: () async {
              await context.push('/notes/new');
              ref.invalidate(notesListProvider);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Search bar.
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
                    hintText: s.isId ? 'Cari note...' : 'Search notes...',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: cs.onSurfaceVariant,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: cs.onSurfaceVariant,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
            ),

            // Notes list.
            Expanded(
              child: _searching
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : _searchResults != null
                      ? _buildNotesList(_searchResults!, cs, extras, s)
                      : notesAsync.when(
                          loading: () => const Center(
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                          error: (e, _) =>
                              Center(child: Text('Error: $e')),
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
                    ? (s.isId ? 'Tidak ada hasil' : 'No results')
                    : (s.isId ? 'Belum ada note' : 'No notes yet'),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _searchResults != null
                    ? (s.isId
                        ? 'Coba kata kunci lain.'
                        : 'Try a different keyword.')
                    : (s.isId
                        ? 'Buat note pertamamu atau minta agen mencatat sesuatu.'
                        : 'Create your first note or ask your agent to jot something down.'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurfaceVariant,
                ),
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
        return _NoteCard(
          note: note,
          onTap: () async {
            await context.push('/notes/${note.id}');
            ref.invalidate(notesListProvider);
          },
        );
      },
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note, required this.onTap});
  final Note note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final timeAgo = _formatTimeAgo(note.updatedAt);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: extras.card,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: extras.subtleBorder),
            ),
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
                    note.content.replaceAll(RegExp(r'[#*\-_>`]'), '').trim(),
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
                                color: cs.primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
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
