import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../settings/data/app_language_provider.dart';
import 'notes_list_screen.dart';
import 'notes_models.dart';

/// Detail screen for viewing a note with rendered markdown.
class NoteDetailScreen extends ConsumerStatefulWidget {
  const NoteDetailScreen({super.key, required this.noteId});
  final String noteId;

  @override
  ConsumerState<NoteDetailScreen> createState() => _NoteDetailScreenState();
}

class _NoteDetailScreenState extends ConsumerState<NoteDetailScreen> {
  Note? _note;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(notesRepositoryProvider);
    final note = await repo.getNote(widget.noteId);
    if (mounted) setState(() { _note = note; _loading = false; });
  }

  Future<void> _delete() async {
    final langPref = ref.read(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));
    final confirmed = await showMeowConfirmDialog(
      context,
      isId: s.isId,
      title: s.noteDetailDeleteTitle,
      message: s.noteDetailDeleteMessage,
      confirmLabel: s.delete,
      cancelLabel: s.cancel,
    );
    if (confirmed && mounted) {
      await ref.read(notesRepositoryProvider).deleteNote(widget.noteId);
      ref.invalidate(notesListProvider);
      if (mounted) context.pop();
    }
  }

  Future<void> _togglePin() async {
    if (_note == null) return;
    final repo = ref.read(notesRepositoryProvider);
    final updated = await repo.updateNote(
      _note!.id,
      pinned: !_note!.pinned,
    );
    setState(() => _note = updated);
    ref.invalidate(notesListProvider);
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    if (_loading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_note == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Text(
            s.noteDetailNotFound,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _note!.title,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _note!.pinned
                  ? Icons.push_pin_rounded
                  : Icons.push_pin_outlined,
              size: 20,
            ),
            tooltip: _note!.pinned ? s.noteDetailUnpin : s.noteDetailPin,
            onPressed: _togglePin,
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            tooltip: s.isId ? 'Edit' : 'Edit',
            onPressed: () async {
              await context.push('/notes/${_note!.id}/edit');
              _load();
            },
          ),
          IconButton(
            icon: Icon(Icons.delete_outline_rounded, size: 20, color: cs.error),
            tooltip: s.delete,
            onPressed: _delete,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Tags.
              if (_note!.tags.isNotEmpty) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: _note!.tags
                      .map((tag) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: cs.primary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              tag,
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.primary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 16),
              ],

              // Markdown content.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: extras.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: extras.subtleBorder),
                ),
                child: GptMarkdown(
                  _note!.content.isEmpty
                      ? s.noteDetailEmptyContent
                      : _note!.content,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ),

              // Metadata.
              const SizedBox(height: 20),
              Text(
                s.noteDetailCreated(_formatDate(_note!.createdAt)),
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                s.noteDetailUpdated(_formatDate(_note!.updatedAt)),
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                ),
              ),
              if (_note!.source.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  s.noteDetailSourceLabel(_note!.source),
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
