import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../../core/storage/agent_event_repository.dart';
import '../../../core/storage/agent_memory_repository.dart';
import '../../../core/storage/agent_soul_repository.dart';
import '../../settings/data/app_language_provider.dart';

// ==========================================================================
// Soul Editor Screen
// ==========================================================================

/// Full-screen editor for agent soul (user profile fields).
class AgentSoulEditorScreen extends ConsumerStatefulWidget {
  const AgentSoulEditorScreen({
    super.key,
    required this.agentId,
    required this.agentName,
  });

  final String agentId;
  final String agentName;

  @override
  ConsumerState<AgentSoulEditorScreen> createState() =>
      _AgentSoulEditorScreenState();
}

class _AgentSoulEditorScreenState
    extends ConsumerState<AgentSoulEditorScreen> {
  final _nameCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController();
  final _langCtrl = TextEditingController();
  final _tzCtrl = TextEditingController();
  final _roleCtrl = TextEditingController();
  final _projectCtrl = TextEditingController();
  final _commCtrl = TextEditingController();
  final _designCtrl = TextEditingController();
  final _personaCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _hasChanges = false;

  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(agentSoulRepositoryProvider);
    final soul = await repo.get(widget.agentId);
    if (!mounted) return;
    if (soul != null) {
      _nameCtrl.text = soul.userName ?? '';
      _nicknameCtrl.text = soul.userNickname ?? '';
      _langCtrl.text = soul.preferredLanguage ?? '';
      _tzCtrl.text = soul.timezone ?? '';
      _roleCtrl.text = soul.workRole ?? '';
      _projectCtrl.text = soul.mainProject ?? '';
      _commCtrl.text = soul.communicationStyle ?? '';
      _designCtrl.text = soul.designPreference ?? '';
      _personaCtrl.text = soul.persona ?? '';
    }
    setState(() => _loading = false);
    // Track changes after initial load.
    for (final c in _allControllers) {
      c.addListener(_markChanged);
    }
  }

  List<TextEditingController> get _allControllers => [
        _nameCtrl,
        _nicknameCtrl,
        _langCtrl,
        _tzCtrl,
        _roleCtrl,
        _projectCtrl,
        _commCtrl,
        _designCtrl,
        _personaCtrl,
      ];

  void _markChanged() {
    if (!_hasChanges && mounted) setState(() => _hasChanges = true);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final repo = ref.read(agentSoulRepositoryProvider);
      final existing = await repo.get(widget.agentId);
      final soul = (existing ??
              AgentSoul(
                agentId: widget.agentId,
                updatedAt: DateTime.now(),
              ))
          .copyWith(
        userName: _nameCtrl.text.trim(),
        userNickname: _nicknameCtrl.text.trim(),
        preferredLanguage: _langCtrl.text.trim(),
        timezone: _tzCtrl.text.trim(),
        workRole: _roleCtrl.text.trim(),
        mainProject: _projectCtrl.text.trim(),
        communicationStyle: _commCtrl.text.trim(),
        designPreference: _designCtrl.text.trim(),
        persona: _personaCtrl.text.trim(),
      );
      await repo.updateAll(soul);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _hasChanges = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.soulSaved),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    for (final c in _allControllers) {
      c.removeListener(_markChanged);
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    ref.watch(appLanguageProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('${s.agentSoulTitle} — ${widget.agentName}'),
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
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                children: [
                  // Subtitle banner.
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Text(
                      s.soulEditorSubtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ),
                  _buildField(
                    s.soulFieldName, _nameCtrl, cs,
                    hint: s.soulFieldNameHint,
                  ),
                  _buildField(
                    s.soulFieldNickname, _nicknameCtrl, cs,
                    hint: s.soulFieldNicknameHint,
                  ),
                  _buildField(
                    s.soulFieldLanguage, _langCtrl, cs,
                    hint: s.soulFieldLanguageHint,
                  ),
                  _buildField(
                    s.soulFieldTimezone, _tzCtrl, cs,
                    hint: s.soulFieldTimezoneHint,
                  ),
                  _buildField(
                    s.soulFieldWorkRole, _roleCtrl, cs,
                    hint: s.soulFieldWorkRoleHint,
                  ),
                  _buildField(
                    s.soulFieldProject, _projectCtrl, cs,
                    hint: s.soulFieldProjectHint,
                  ),
                  _buildField(
                    s.soulFieldCommStyle, _commCtrl, cs,
                    hint: s.soulFieldCommStyleHint,
                  ),
                  _buildField(
                    s.soulFieldDesignPref, _designCtrl, cs,
                    hint: s.soulFieldDesignPrefHint,
                  ),
                  _buildField(
                    s.soulFieldPersona, _personaCtrl, cs,
                    hint: s.soulFieldPersonaHint,
                    maxLines: 4,
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildField(
    String label,
    TextEditingController ctrl,
    ColorScheme cs, {
    String? hint,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: MeowInput(
        controller: ctrl,
        label: label,
        hint: hint,
        maxLines: maxLines,
      ),
    );
  }
}

// ==========================================================================
// Memory Editor Screen
// ==========================================================================

class AgentMemoryEditorScreen extends ConsumerStatefulWidget {
  const AgentMemoryEditorScreen({
    super.key,
    required this.agentId,
    required this.agentName,
  });

  final String agentId;
  final String agentName;

  @override
  ConsumerState<AgentMemoryEditorScreen> createState() =>
      _AgentMemoryEditorScreenState();
}

class _AgentMemoryEditorScreenState
    extends ConsumerState<AgentMemoryEditorScreen> {
  final _addController = TextEditingController();
  String _addCategory = 'fact';

  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }

  String _categoryLabel(String cat) {
    switch (cat) {
      case 'fact':
        return s.memoryCategoryFact;
      case 'preference':
        return s.memoryCategoryPreference;
      case 'bookmark':
        return s.memoryCategoryBookmark;
      case 'session':
        return s.memoryCategorySession;
      default:
        return cat;
    }
  }

  Future<void> _addEntry() async {
    final text = _addController.text.trim();
    if (text.isEmpty) return;
    await ref.read(agentMemoryRepositoryProvider).append(
          agentId: widget.agentId,
          content: text,
          category: _addCategory,
        );
    _addController.clear();
    ref.invalidate(agentMemoryStreamProvider(widget.agentId));
  }

  Future<void> _deleteEntry(AgentMemoryEntry entry) async {
    final confirmed = await showMeowConfirmDialog(
      context,
      isId: s.isId,
      title: s.delete,
      message: s.memoryDeleteConfirm,
      confirmLabel: s.delete,
      cancelLabel: s.cancel,
    );
    if (!confirmed || !mounted) return;
    await ref
        .read(agentMemoryRepositoryProvider)
        .delete(entry.id, agentId: widget.agentId);
    ref.invalidate(agentMemoryStreamProvider(widget.agentId));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.memoryDeleted),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    ref.watch(appLanguageProvider);
    final memoryAsync = ref.watch(agentMemoryStreamProvider(widget.agentId));

    return Scaffold(
      appBar: AppBar(
        title: Text('${s.agentMemoryTitle} — ${widget.agentName}'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Add entry bar.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  // Category chip.
                  PopupMenuButton<String>(
                    initialValue: _addCategory,
                    onSelected: (v) => setState(() => _addCategory = v),
                    itemBuilder: (_) => [
                      for (final cat in ['fact', 'preference', 'bookmark', 'session'])
                        PopupMenuItem(
                          value: cat,
                          child: Text(_categoryLabel(cat)),
                        ),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: cs.primary.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _categoryLabel(_addCategory),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: cs.primary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.arrow_drop_down_rounded,
                            size: 18,
                            color: cs.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _addController,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface,
                      ),
                      decoration: InputDecoration(
                        hintText: s.memoryContentHint,
                        filled: true,
                        fillColor: extras.inputFill,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: extras.inputBorder),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: extras.inputBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide:
                              BorderSide(color: extras.inputFocusBorder),
                        ),
                      ),
                      onSubmitted: (_) => _addEntry(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(Icons.add_rounded, color: cs.primary),
                    onPressed: _addEntry,
                    tooltip: s.memoryAddEntry,
                  ),
                ],
              ),
            ),

            // Memory list.
            Expanded(
              child: memoryAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('$e')),
                data: (entries) {
                  if (entries.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          s.memoryEmpty,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final entry = entries[i];
                      final date = entry.createdAt
                          .toIso8601String()
                          .split('T')
                          .first;
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: extras.card,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: extras.subtleBorder),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: cs.primary
                                              .withValues(alpha: 0.10),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          _categoryLabel(entry.category),
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: cs.primary,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        date,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    entry.content,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: cs.onSurface,
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () => _deleteEntry(entry),
                              child: Icon(
                                Icons.close_rounded,
                                size: 16,
                                color: cs.onSurfaceVariant
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================================================
// Heartbeat Viewer Screen
// ==========================================================================

class AgentHeartbeatScreen extends ConsumerStatefulWidget {
  const AgentHeartbeatScreen({
    super.key,
    required this.agentId,
    required this.agentName,
  });

  final String agentId;
  final String agentName;

  @override
  ConsumerState<AgentHeartbeatScreen> createState() =>
      _AgentHeartbeatScreenState();
}

class _AgentHeartbeatScreenState
    extends ConsumerState<AgentHeartbeatScreen> {
  List<AgentEvent>? _events;
  bool _loading = true;

  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final events = await ref
        .read(agentEventRepositoryProvider)
        .recent(widget.agentId, limit: 50);
    if (!mounted) return;
    setState(() {
      _events = events;
      _loading = false;
    });
  }

  IconData _eventIcon(String type) {
    switch (type) {
      case 'task_started':
        return Icons.play_circle_outline_rounded;
      case 'task_completed':
        return Icons.check_circle_outline_rounded;
      case 'error':
        return Icons.error_outline_rounded;
      case 'idle':
        return Icons.pause_circle_outline_rounded;
      default:
        return Icons.circle_outlined;
    }
  }

  Color _eventColor(String type, ColorScheme cs) {
    switch (type) {
      case 'task_completed':
        return const Color(0xFF22C55E);
      case 'error':
        return cs.error;
      case 'task_started':
        return cs.primary;
      default:
        return cs.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    ref.watch(appLanguageProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('${s.agentHeartbeatTitle} — ${widget.agentName}'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : (_events == null || _events!.isEmpty)
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        s.heartbeatEmpty,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: _events!.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final ev = _events![i];
                      final time = '${ev.createdAt.hour.toString().padLeft(2, '0')}:'
                          '${ev.createdAt.minute.toString().padLeft(2, '0')}';
                      final date = ev.createdAt
                          .toIso8601String()
                          .split('T')
                          .first;
                      final color = _eventColor(ev.eventType, cs);
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: extras.card,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: extras.subtleBorder),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(_eventIcon(ev.eventType),
                                size: 18, color: color),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding:
                                            const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: color
                                              .withValues(alpha: 0.12),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          ev.eventType,
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                            color: color,
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      Text(
                                        '$date $time',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (ev.task != null &&
                                      ev.task!.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      ev.task!,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: cs.onSurface,
                                        height: 1.35,
                                      ),
                                    ),
                                  ],
                                  if (ev.lastTool != null &&
                                      ev.lastTool!.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      'Tool: ${ev.lastTool}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontFamily: 'monospace',
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
