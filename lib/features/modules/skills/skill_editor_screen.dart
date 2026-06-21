import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../../core/storage/agent_skills_repository.dart';
import '../../agents/data/agent_model.dart';
import '../../agents/data/agent_repository.dart';
import '../../settings/data/app_language_provider.dart';

class SkillEditorScreen extends ConsumerStatefulWidget {
  const SkillEditorScreen({super.key, this.skillId});
  final String? skillId;

  @override
  ConsumerState<SkillEditorScreen> createState() => _SkillEditorScreenState();
}

class _SkillEditorScreenState extends ConsumerState<SkillEditorScreen> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _githubUrlController = TextEditingController();
  
  bool _loading = true;
  bool _saving = false;
  bool _fetching = false;
  bool _isEnabled = true;
  final Set<String> _assignedAgentIds = {};
  int _selectedTabIndex = 0;
  
  AgentSkill? _existing;

  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }

  bool get _isEditing => widget.skillId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_isEditing) {
      final repo = ref.read(agentSkillsRepositoryProvider);
      final skill = await repo.getById(widget.skillId!);
      if (skill != null && mounted) {
        _existing = skill;
        _titleController.text = skill.title;
        _contentController.text = skill.content;
        _githubUrlController.text = skill.githubUrl ?? '';
        _isEnabled = skill.isEnabled;
        _assignedAgentIds.addAll(skill.assignedAgentIds);
        if (skill.githubUrl != null && skill.githubUrl!.isNotEmpty) {
          _selectedTabIndex = 1;
        }
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _importMarkdown() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['md', 'txt'],
      );
      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final content = await file.readAsString();
        _contentController.text = content;
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.skillImportSuccess)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.skillImportError)),
      );
    }
  }

  GithubUrlInfo? _parseGithubUrl(String url) {
    var clean = url.trim();
    if (clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }

    final regExp = RegExp(
      r'^https?://(?:www\.)?github\.com/([^/]+)/([^/]+)(?:/(?:tree|blob)/([^/]+)(?:/(.+))?)?$',
      caseSensitive: false,
    );
    
    final match = regExp.firstMatch(clean);
    if (match == null) return null;

    final owner = match.group(1)!;
    final repo = match.group(2)!;
    final branch = match.group(3) ?? 'main';
    final path = match.group(4) ?? '';

    return GithubUrlInfo(
      owner: owner,
      repo: repo,
      branch: branch,
      path: path,
    );
  }

  Future<void> _fetchFromGithub() async {
    final url = _githubUrlController.text.trim();
    if (url.isEmpty) return;

    if (url.toLowerCase().endsWith('.md')) {
      var targetUrl = url;
      if (url.contains('github.com') && !url.contains('raw.githubusercontent.com')) {
        targetUrl = url
            .replaceAll('github.com', 'raw.githubusercontent.com')
            .replaceAll('/blob/', '/');
      }

      setState(() => _fetching = true);
      try {
        final dio = Dio();
        final response = await dio.get<String>(targetUrl);
        if (response.data != null) {
          _contentController.text = response.data!;
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.skillFetchSuccess)),
          );
        } else {
          throw Exception('Empty response');
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.skillFetchError)),
        );
      } finally {
        if (mounted) setState(() => _fetching = false);
      }
    } else {
      final info = _parseGithubUrl(url);
      if (info == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.skillFetchError)),
        );
        return;
      }
      await _exploreGithubRepository(info);
    }
  }

  Future<void> _exploreGithubRepository(GithubUrlInfo info) async {
    setState(() => _fetching = true);
    try {
      final dio = Dio();
      var path = info.path;

      // Automatically dive into 'skills' or 'agent-skills' folder if path is empty (root)
      if (path.isEmpty) {
        final rootApiUrl = 'https://api.github.com/repos/${info.owner}/${info.repo}/contents?ref=${info.branch}';
        final rootRes = await dio.get<List<dynamic>>(rootApiUrl);
        if (rootRes.data != null) {
          final rootItems = rootRes.data!.map((item) => item as Map<String, dynamic>).toList();
          final skillsDir = rootItems.firstWhere(
            (item) =>
                item['type'] == 'dir' &&
                ((item['name'] as String).toLowerCase() == 'skills' ||
                    (item['name'] as String).toLowerCase() == 'agent-skills'),
            orElse: () => <String, dynamic>{},
          );
          if (skillsDir.isNotEmpty) {
            path = skillsDir['path'] as String;
          }
        }
      }

      final apiUrl = 'https://api.github.com/repos/${info.owner}/${info.repo}/contents/$path?ref=${info.branch}';
      
      final response = await dio.get<List<dynamic>>(apiUrl);
      if (response.data == null) {
        throw Exception('Empty directory');
      }

      final items = response.data!.map((item) => item as Map<String, dynamic>).toList();
      
      final filteredItems = items.where((item) {
        final name = (item['name'] as String).toLowerCase();
        final type = item['type'] as String;
        if (name.startsWith('.')) return false;
        if (type == 'dir') return true;
        if (type == 'file' && name.endsWith('.md')) return true;
        return false;
      }).toList();

      if (filteredItems.isEmpty) {
        throw Exception('No skills (folders or markdown files) found in this path');
      }

      final resolvedInfo = GithubUrlInfo(
        owner: info.owner,
        repo: info.repo,
        branch: info.branch,
        path: path,
      );

      if (!mounted) return;
      await _showBulkImportSheet(resolvedInfo, filteredItems);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${s.skillFetchError}: $e')),
      );
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _showBulkImportSheet(GithubUrlInfo info, List<Map<String, dynamic>> items) async {
    final selectedItems = <Map<String, dynamic>>{};
    selectedItems.addAll(items); // Default select all

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final cs = context.cs;
            final isImporting = _saving;

            return MeowSheet(
              title: s.skillBulkImportTitle,
              subtitle: '${info.owner}/${info.repo}/${info.path}',
              children: [
                if (isImporting)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(strokeWidth: 2),
                          const SizedBox(height: 16),
                          Text(
                            s.skillBulkImportSearching,
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else ...[
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.4,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final name = item['name'] as String;
                        final type = item['type'] as String;
                        final isDir = type == 'dir';
                        final isChecked = selectedItems.contains(item);

                        final formattedName = name
                            .replaceAll('-', ' ')
                            .replaceAll('_', ' ')
                            .split(' ')
                            .map((word) => word.isNotEmpty
                                ? '${word[0].toUpperCase()}${word.substring(1)}'
                                : '')
                            .join(' ');

                        return CheckboxListTile(
                          value: isChecked,
                          title: Text(
                            formattedName,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: cs.onSurface,
                            ),
                          ),
                          subtitle: Text(
                            isDir ? 'Directory' : 'Markdown File',
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          secondary: Icon(
                            isDir ? Icons.folder_open_rounded : Icons.description_outlined,
                            color: cs.primary,
                          ),
                          onChanged: (val) {
                            setSheetState(() {
                              if (val == true) {
                                selectedItems.add(item);
                              } else {
                                selectedItems.remove(item);
                              }
                            });
                          },
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: MeowPrimaryButton(
                      label: s.skillBulkImportButton(selectedItems.length),
                      onPressed: selectedItems.isEmpty
                          ? null
                          : () async {
                              setSheetState(() {
                                // Trigger loading view inside sheet state
                              });
                              await _performBulkImport(info, selectedItems.toList(), setSheetState);
                            },
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _performBulkImport(
    GithubUrlInfo info,
    List<Map<String, dynamic>> itemsToImport,
    StateSetter setSheetState,
  ) async {
    setSheetState(() {
      _saving = true;
    });

    final dio = Dio();
    final repo = ref.read(agentSkillsRepositoryProvider);
    var successCount = 0;

    try {
      for (final item in itemsToImport) {
        final name = item['name'] as String;
        final type = item['type'] as String;
        final path = item['path'] as String;
        
        final title = name
            .replaceAll('-', ' ')
            .replaceAll('_', ' ')
            .split(' ')
            .map((word) => word.isNotEmpty
                ? '${word[0].toUpperCase()}${word.substring(1)}'
                : '')
            .join(' ');

        String? content;
        String? finalGithubUrl;

        if (type == 'file') {
          final downloadUrl = item['download_url'] as String?;
          if (downloadUrl != null) {
            final fileRes = await dio.get<String>(downloadUrl);
            content = fileRes.data;
            finalGithubUrl = item['html_url'] as String?;
          }
        } else if (type == 'dir') {
          final dirApiUrl = 'https://api.github.com/repos/${info.owner}/${info.repo}/contents/$path?ref=${info.branch}';
          final dirRes = await dio.get<List<dynamic>>(dirApiUrl);
          
          if (dirRes.data != null) {
            final dirItems = dirRes.data!.map((di) => di as Map<String, dynamic>).toList();
            
            var targetMdFile = dirItems.firstWhere(
              (di) => di['type'] == 'file' && (di['name'] as String).toLowerCase() == 'readme.md',
              orElse: () => dirItems.firstWhere(
                (di) => di['type'] == 'file' && (di['name'] as String).toLowerCase().endsWith('.md'),
                orElse: () => <String, dynamic>{},
              ),
            );

            if (targetMdFile.isNotEmpty) {
              final downloadUrl = targetMdFile['download_url'] as String?;
              if (downloadUrl != null) {
                final fileRes = await dio.get<String>(downloadUrl);
                content = fileRes.data;
                finalGithubUrl = targetMdFile['html_url'] as String?;
              }
            }
          }
        }

        if (content != null && content.trim().isNotEmpty) {
          final skill = AgentSkill(
            id: const Uuid().v4(),
            title: title,
            content: content,
            githubUrl: finalGithubUrl,
            isEnabled: true,
            createdAt: DateTime.now(),
            assignedAgentIds: _assignedAgentIds.toList(),
          );
          await repo.save(skill);
          successCount++;
        }
      }

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.skillBulkImportSuccess(successCount))),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${s.skillFetchError}: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }


  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.skillTitleRequired)),
      );
      return;
    }

    String? githubUrl;
    if (_selectedTabIndex == 1) {
      final url = _githubUrlController.text.trim();
      if (url.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.skillGithubUrlRequired)),
        );
        return;
      }
      githubUrl = url;
    }

    final content = _contentController.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.skillContentRequired)),
      );
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(agentSkillsRepositoryProvider);

    try {
      final skill = AgentSkill(
        id: _isEditing ? widget.skillId! : const Uuid().v4(),
        title: title,
        content: content,
        githubUrl: githubUrl,
        isEnabled: _isEnabled,
        createdAt: _isEditing ? _existing!.createdAt : DateTime.now(),
        assignedAgentIds: _assignedAgentIds.toList(),
      );

      await repo.save(skill);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.skillSaveSuccess)),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.errorWithMessage('$e'))),
        );
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showMeowConfirmDialog(
      context,
      strings: s,
      title: s.skillDeleteConfirm,
      message: s.skillDeleteConfirmDesc,
    );
    if (confirmed && mounted) {
      setState(() => _saving = true);
      try {
        final repo = ref.read(agentSkillsRepositoryProvider);
        await repo.delete(widget.skillId!);
        if (mounted) {
          context.pop();
        }
      } catch (e) {
        if (mounted) {
          setState(() => _saving = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.errorWithMessage('$e'))),
          );
        }
      }
    }
  }

  void _showAssigneeSheet(List<AgentModel> allAgents) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final cs = context.cs;
            return MeowSheet(
              title: s.skillAssignees,
              subtitle: s.skillAssigneesDesc,
              children: [
                if (allAgents.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        s.workflowNoAgentsYet,
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                  )
                else
                  ...allAgents.map((agent) {
                    final isChecked = _assignedAgentIds.contains(agent.id);
                    return CheckboxListTile(
                      title: Row(
                        children: [
                          MeowAgentIcon(agent: agent, size: 28),
                          const SizedBox(width: 10),
                          Text(
                            agent.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                            ),
                          ),
                        ],
                      ),
                      value: isChecked,
                      activeColor: cs.primary,
                      onChanged: (bool? value) {
                        setSheetState(() {
                          if (value == true) {
                            _assignedAgentIds.add(agent.id);
                          } else {
                            _assignedAgentIds.remove(agent.id);
                          }
                        });
                        setState(() {}); // update screen
                      },
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    );
                  }),
              ],
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _githubUrlController.dispose();
    super.dispose();
  }

  Widget _buildTabButton(int index, String label, ColorScheme cs, MeowExtras extras) {
    final isSelected = _selectedTabIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedTabIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected 
              ? cs.primary.withValues(alpha: 0.12)
              : extras.card.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected 
                ? cs.primary.withValues(alpha: 0.4) 
                : extras.subtleBorder,
            width: 1.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? cs.primary : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final agents = ref.watch(agentListProvider);
    final assignedAgents = agents.where((a) => _assignedAgentIds.contains(a.id)).toList();

    if (_loading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? s.skillEdit : s.skillCreate),
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
                MeowInput(
                  controller: _titleController,
                  label: s.skillTitleLabel,
                  hint: s.skillTitleHint,
                ),
                const SizedBox(height: 20),

                Row(
                  children: [
                    Expanded(
                      child: _buildTabButton(0, s.skillTabManual, cs, extras),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _buildTabButton(1, s.skillTabGithub, cs, extras),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                if (_selectedTabIndex == 0) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        s.skillContentLabel,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _importMarkdown,
                        icon: const Icon(Icons.upload_file_rounded, size: 16),
                        label: Text(s.skillImport, style: const TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  MeowInput(
                    controller: _contentController,
                    hint: s.skillContentHint,
                    maxLines: 8,
                    keyboardType: TextInputType.multiline,
                  ),
                ] else ...[
                  Row(
                    children: [
                      Expanded(
                        child: MeowInput(
                          controller: _githubUrlController,
                          label: s.skillGithubUrlLabel,
                          hint: s.skillGithubUrlHint,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(top: 22),
                        child: _fetching
                            ? const SizedBox(
                                width: 36,
                                height: 36,
                                child: Padding(
                                  padding: EdgeInsets.all(8.0),
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : IconButton(
                                icon: const Icon(Icons.download_rounded),
                                tooltip: s.skillFetch,
                                onPressed: _fetchFromGithub,
                              ),
                      ),
                    ],
                  ),
                  if (_contentController.text.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      s.skillDownloadedContentPreview,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    MeowInput(
                      controller: _contentController,
                      maxLines: 8,
                      readOnly: true,
                    ),
                  ],
                ],
                const SizedBox(height: 24),

                Text(
                  s.skillAssignees,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => _showAssigneeSheet(agents),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                    decoration: BoxDecoration(
                      color: extras.card,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: extras.subtleBorder),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: assignedAgents.isNotEmpty
                              ? Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: assignedAgents.map((agent) {
                                    return Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: cs.primary.withValues(alpha: 0.08),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          MeowAgentIcon(agent: agent, size: 16),
                                          const SizedBox(width: 4),
                                          Text(
                                            agent.name,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: cs.primary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                )
                              : Text(
                                  s.workflowChooseAgent,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                                  ),
                                ),
                        ),
                        Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 16,
                          color: cs.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      s.skillEnabledLabel,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                    Switch(
                      value: _isEnabled,
                      activeThumbColor: cs.primary,
                      onChanged: (val) {
                        setState(() => _isEnabled = val);
                      },
                    ),
                  ],
                ),
                if (_isEditing) ...[
                  const SizedBox(height: 32),
                  MeowSecondaryButton(
                    label: s.skillDeleteButton,
                    icon: Icons.delete_outline_rounded,
                    onPressed: _delete,
                    danger: true,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class GithubUrlInfo {
  final String owner;
  final String repo;
  final String branch;
  final String path;

  GithubUrlInfo({
    required this.owner,
    required this.repo,
    required this.branch,
    required this.path,
  });
}
