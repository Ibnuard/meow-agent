import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../settings/data/app_language_provider.dart';
import '../data/workspace_service.dart';

/// Lists the workspace files for an agent.
class WorkspaceDirectoryScreen extends ConsumerStatefulWidget {
  const WorkspaceDirectoryScreen({
    super.key,
    required this.workspacePath,
    required this.agentName,
  });

  final String workspacePath;
  final String agentName;

  @override
  ConsumerState<WorkspaceDirectoryScreen> createState() =>
      _WorkspaceDirectoryScreenState();
}

class _WorkspaceDirectoryScreenState extends ConsumerState<WorkspaceDirectoryScreen> {
  List<FileSystemEntity> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    final dir = Directory(widget.workspacePath);
    if (await dir.exists()) {
      final entities = await dir.list().toList();
      // Sort: directories first, then files alphabetically.
      entities.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir && !bIsDir) return -1;
        if (!aIsDir && bIsDir) return 1;
        final aName = a.path.split(Platform.pathSeparator).last.toLowerCase();
        final bName = b.path.split(Platform.pathSeparator).last.toLowerCase();
        return aName.compareTo(bName);
      });
      if (mounted) setState(() { _files = entities; _loading = false; });
    } else {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fileName(FileSystemEntity entity) {
    return entity.path.split(Platform.pathSeparator).last;
  }

  IconData _fileIcon(FileSystemEntity entity) {
    if (entity is Directory) return Icons.folder_outlined;
    final name = _fileName(entity).toLowerCase();
    if (name.endsWith('.md') || name.endsWith('.txt')) {
      return Icons.description_outlined;
    }
    if (name.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (name.endsWith('.json') ||
        name.endsWith('.yaml') ||
        name.endsWith('.yml')) {
      return Icons.data_object_outlined;
    }
    if (name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.gif') ||
        name.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  String _fileDescription(FileSystemEntity entity, AppStrings s) {
    if (entity is Directory) return s.wdFolderDesc;
    return s.wdDefaultFileDesc;
  }

  Future<void> _openInFileManager() async {
    final langPref = ref.read(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));
    final ws = ref.read(workspaceServiceProvider);
    final opened = await ws.openInFileManager(widget.agentName);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.wdCannotOpenFileManager)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.agentName),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _files.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        s.wdEmptyWorkspace,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                  )
                : Column(
                children: [
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                      itemCount: _files.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final file = _files[i];
                        final name = _fileName(file);
                        final icon = _fileIcon(file);
                        final desc = _fileDescription(file, s);

                        return Material(
                          color: extras.card,
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () async {
                              if (file is Directory) return;
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => WorkspaceFileEditorScreen(
                                    filePath: file.path,
                                    fileName: name,
                                  ),
                                ),
                              );
                              _loadFiles();
                            },
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border:
                                    Border.all(color: extras.subtleBorder),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color:
                                          cs.primary.withValues(alpha: 0.1),
                                      borderRadius:
                                          BorderRadius.circular(12),
                                    ),
                                    alignment: Alignment.center,
                                    child: Icon(icon,
                                        size: 20, color: cs.primary),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          name,
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: cs.onSurface,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          desc,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: cs.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    size: 20,
                                    color: cs.onSurfaceVariant
                                        .withValues(alpha: 0.5),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                  // Open in File Manager button.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _openInFileManager,
                        icon: const Icon(Icons.folder_open_rounded, size: 18),
                        label: Text(s.wdOpenFileManager),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: cs.primary,
                          side: BorderSide(
                            color: cs.primary.withValues(alpha: 0.3),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Simple markdown file editor.
class WorkspaceFileEditorScreen extends ConsumerStatefulWidget {
  const WorkspaceFileEditorScreen({
    super.key,
    required this.filePath,
    required this.fileName,
  });

  final String filePath;
  final String fileName;

  @override
  ConsumerState<WorkspaceFileEditorScreen> createState() =>
      _WorkspaceFileEditorScreenState();
}

class _WorkspaceFileEditorScreenState extends ConsumerState<WorkspaceFileEditorScreen> {
  final _controller = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _loadContent();
  }

  Future<void> _loadContent() async {
    final file = File(widget.filePath);
    if (await file.exists()) {
      final content = await file.readAsString();
      _controller.text = content;
    }
    if (mounted) setState(() => _loading = false);
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    if (!_hasChanges) setState(() => _hasChanges = true);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await File(widget.filePath).writeAsString(_controller.text);
      if (mounted) {
        final langPref = ref.read(appLanguageProvider);
        final s = AppStrings(resolveLanguageCode(langPref));
        setState(() {
          _saving = false;
          _hasChanges = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.wdSaved)),
        );
      }
    } catch (e) {
      if (mounted) {
        final langPref = ref.read(appLanguageProvider);
        final s = AppStrings(resolveLanguageCode(langPref));
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${s.wdErrorSaving}$e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.fileName),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (_hasChanges)
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
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Container(
                  decoration: BoxDecoration(
                    color: extras.inputFill,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: extras.subtleBorder),
                  ),
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: cs.onSurface,
                      height: 1.5,
                    ),
                    decoration: const InputDecoration(
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      contentPadding: EdgeInsets.all(16),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
