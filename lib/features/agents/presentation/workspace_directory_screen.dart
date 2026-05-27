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

  /// Only show these core workspace files.
  static const _coreFiles = ['SOUL.md', 'MEMORY.md', 'SKILLS.md', 'HEARTBEAT.md'];

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    final dir = Directory(widget.workspacePath);
    if (await dir.exists()) {
      final entities = await dir.list().toList();
      // Filter to only core .md files.
      final filtered = entities.where((e) {
        final name = e.path.split(Platform.pathSeparator).last;
        return _coreFiles.contains(name);
      }).toList();
      // Sort in defined order.
      filtered.sort((a, b) {
        final aName = a.path.split(Platform.pathSeparator).last;
        final bName = b.path.split(Platform.pathSeparator).last;
        return _coreFiles.indexOf(aName).compareTo(_coreFiles.indexOf(bName));
      });
      if (mounted) setState(() => _files = filtered);
    }
  }

  String _fileName(FileSystemEntity entity) {
    return entity.path.split(Platform.pathSeparator).last;
  }

  IconData _fileIcon(String name) {
    switch (name) {
      case 'SKILLS.md':
        return Icons.build_outlined;
      case 'SOUL.md':
        return Icons.psychology_outlined;
      case 'HEARTBEAT.md':
        return Icons.monitor_heart_outlined;
      case 'MEMORY.md':
        return Icons.memory_outlined;
      default:
        return Icons.description_outlined;
    }
  }

  String _fileDescription(String name) {
    switch (name) {
      case 'SKILLS.md':
        return 'Tools and modules this agent can use';
      case 'SOUL.md':
        return 'Personality, system prompt, and safety mode';
      case 'HEARTBEAT.md':
        return 'Scheduled tasks and event triggers';
      case 'MEMORY.md':
        return 'Persistent memory across sessions';
      default:
        return 'Workspace file';
    }
  }

  Future<void> _openInFileManager() async {
    final ws = ref.read(workspaceServiceProvider);
    final opened = await ws.openInFileManager(widget.agentName);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open file manager.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.agentName),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: _files.isEmpty
            ? const Center(child: CircularProgressIndicator())
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
                        final icon = _fileIcon(name);
                        final desc = _fileDescription(name);

                        return Material(
                          color: extras.card,
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () async {
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
                        label: const Text('Buka di File Manager'),
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
        setState(() {
          _saving = false;
          _hasChanges = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e')),
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
                  : Text(AppStrings(resolveLanguageCode(ref.watch(appLanguageProvider))).save),
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
