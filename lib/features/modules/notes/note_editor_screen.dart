import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../settings/data/app_language_provider.dart';
import 'notes_list_screen.dart';
import 'notes_models.dart';

/// Editor screen for creating or editing a note.
class NoteEditorScreen extends ConsumerStatefulWidget {
  const NoteEditorScreen({super.key, this.noteId});
  final String? noteId;

  @override
  ConsumerState<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends ConsumerState<NoteEditorScreen> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _tagsController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  Note? _existing;

  bool get _isEditing => widget.noteId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_isEditing) {
      final repo = ref.read(notesRepositoryProvider);
      final note = await repo.getNote(widget.noteId!);
      if (note != null && mounted) {
        _existing = note;
        _titleController.text = note.title;
        _contentController.text = note.content;
        _tagsController.text = note.tags.join(', ');
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      final langPref = ref.read(appLanguageProvider);
      final s = AppStrings(resolveLanguageCode(langPref));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.isId ? 'Judul wajib diisi' : 'Title is required'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(notesRepositoryProvider);
    final content = _contentController.text.trim();
    final tags = _tagsController.text
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();

    try {
      if (_isEditing && _existing != null) {
        await repo.updateNote(
          _existing!.id,
          title: title,
          content: content,
          tags: tags,
        );
      } else {
        await repo.createNote(
          title: title,
          content: content,
          tags: tags,
          source: 'user',
        );
      }
      ref.invalidate(notesListProvider);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _tagsController.dispose();
    super.dispose();
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

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing
            ? (s.isId ? 'Edit Note' : 'Edit Note')
            : (s.isId ? 'Note Baru' : 'New Note')),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(s.save),
          ),
        ],
      ),
      body: SafeArea(
        child: GestureDetector(
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          behavior: HitTestBehavior.translucent,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title field.
                Container(
                  decoration: BoxDecoration(
                    color: extras.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: extras.subtleBorder),
                  ),
                  child: TextField(
                    controller: _titleController,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                    decoration: InputDecoration(
                      hintText: s.isId ? 'Judul note' : 'Note title',
                      hintStyle: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                // Tags field.
                Container(
                  decoration: BoxDecoration(
                    color: extras.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: extras.subtleBorder),
                  ),
                  child: TextField(
                    controller: _tagsController,
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                    decoration: InputDecoration(
                      hintText: s.isId
                          ? 'Tag (pisahkan dengan koma)'
                          : 'Tags (comma separated)',
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                      prefixIcon: Icon(
                        Icons.tag_rounded,
                        size: 18,
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

                const SizedBox(height: 14),

                // Content field.
                Container(
                  decoration: BoxDecoration(
                    color: extras.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: extras.subtleBorder),
                  ),
                  child: TextField(
                    controller: _contentController,
                    maxLines: null,
                    minLines: 12,
                    style: TextStyle(
                      fontSize: 14,
                      color: cs.onSurface,
                      height: 1.5,
                    ),
                    decoration: InputDecoration(
                      hintText: s.isId
                          ? 'Tulis konten markdown di sini...'
                          : 'Write markdown content here...',
                      hintStyle: TextStyle(
                        fontSize: 14,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.all(16),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
