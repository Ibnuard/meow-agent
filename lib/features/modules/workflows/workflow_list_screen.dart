import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../settings/data/app_language_provider.dart';
import 'workflow_model.dart';
import 'workflow_repository.dart';
import 'workflow_editor_screen.dart';
import 'workflow_scheduler.dart';
import 'workflow_templates_screen.dart';

/// Lists all workflows with toggle, edit, and delete (with multi-select).
class WorkflowListScreen extends ConsumerStatefulWidget {
  const WorkflowListScreen({super.key});

  @override
  ConsumerState<WorkflowListScreen> createState() => _WorkflowListScreenState();
}

class _WorkflowListScreenState extends ConsumerState<WorkflowListScreen> {
  final WorkflowRepository _repo = WorkflowRepository();
  List<WorkflowModel> _workflows = [];
  bool _loading = true;

  // Multi-select state.
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _repo.list();
    if (mounted) {
      setState(() {
        _workflows = list;
        _loading = false;
      });
    }
  }

  Future<void> _toggle(WorkflowModel wf) async {
    await _repo.toggle(wf.id, !wf.enabled);
    _load();
  }

  void _enterSelection(String id) {
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _selectionMode = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _selectAll() {
    setState(() {
      if (_selectedIds.length == _workflows.length) {
        _selectedIds.clear();
        _selectionMode = false;
      } else {
        _selectedIds
          ..clear()
          ..addAll(_workflows.map((w) => w.id));
      }
    });
  }

  Future<void> _deleteSelected(bool isId) async {
    final count = _selectedIds.length;
    final confirm = await showMeowConfirmDialog(
      context,
      isId: isId,
      title: isId ? 'Hapus Workflow?' : 'Delete Workflows?',
      message: isId
          ? '$count workflow akan dihapus permanen. Lanjutkan?'
          : '$count workflows will be permanently deleted. Continue?',
      confirmLabel: isId ? 'Hapus' : 'Delete',
      cancelLabel: isId ? 'Batal' : 'Cancel',
    );
    if (!confirm) return;

    for (final id in _selectedIds) {
      final wf = _workflows.where((w) => w.id == id).firstOrNull;
      if (wf != null) {
        await WorkflowScheduler.cancel(wf);
        await _repo.delete(id);
      }
    }
    _exitSelection();
    _load();
  }

  void _openEditor({WorkflowModel? workflow}) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => WorkflowEditorScreen(workflow: workflow),
      ),
    );
    if (result == true) _load();
  }

  void _onCardTap(WorkflowModel wf) {
    if (_selectionMode) {
      _toggleSelection(wf.id);
    } else {
      _openEditor(workflow: wf);
    }
  }

  void _onCardLongPress(WorkflowModel wf) {
    if (!_selectionMode) {
      _enterSelection(wf.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final langPref = ref.watch(appLanguageProvider);
    final isId = resolveLanguageCode(langPref) == 'id';

    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _exitSelection();
      },
      child: Scaffold(
        appBar: _selectionMode
            ? _buildSelectionAppBar(cs, isId)
            : _buildDefaultAppBar(isId),
        floatingActionButton: _selectionMode
            ? null
            : FloatingActionButton(
                onPressed: () => _openEditor(),
                backgroundColor: cs.primary,
                child: const Icon(Icons.add_rounded, color: Colors.white),
              ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : _workflows.isEmpty
            ? _buildEmpty(cs, extras, isId)
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
                itemCount: _workflows.length,
                itemBuilder: (_, i) =>
                    _buildCard(_workflows[i], cs, extras, isId),
              ),
      ),
    );
  }

  PreferredSizeWidget _buildDefaultAppBar(bool isId) {
    return AppBar(
      title: Text(isId ? 'Workflows' : 'Workflows'),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: () => context.pop(),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.auto_awesome_rounded),
          tooltip: isId ? 'Template' : 'Templates',
          onPressed: () async {
            final result = await Navigator.push<bool>(
              context,
              MaterialPageRoute(
                builder: (_) => const WorkflowTemplatesScreen(),
              ),
            );
            if (result == true) _load();
          },
        ),
        if (_workflows.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.checklist_rounded),
            tooltip: isId ? 'Pilih' : 'Select',
            onPressed: () {
              if (_workflows.isNotEmpty) {
                _enterSelection(_workflows.first.id);
              }
            },
          ),
      ],
    );
  }

  PreferredSizeWidget _buildSelectionAppBar(ColorScheme cs, bool isId) {
    final count = _selectedIds.length;
    final allSelected = count == _workflows.length;
    return AppBar(
      title: Text(
        isId ? '$count dipilih' : '$count selected',
        style: const TextStyle(fontSize: 16),
      ),
      leading: IconButton(
        icon: const Icon(Icons.close_rounded),
        onPressed: _exitSelection,
      ),
      actions: [
        IconButton(
          icon: Icon(
            allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
          ),
          tooltip: allSelected
              ? (isId ? 'Batal pilih semua' : 'Deselect all')
              : (isId ? 'Pilih semua' : 'Select all'),
          onPressed: _selectAll,
        ),
        IconButton(
          icon: const Icon(
            Icons.delete_outline_rounded,
            color: Colors.redAccent,
          ),
          tooltip: isId ? 'Hapus' : 'Delete',
          onPressed: count > 0 ? () => _deleteSelected(isId) : null,
        ),
      ],
    );
  }

  Widget _buildEmpty(ColorScheme cs, MeowExtras extras, bool isId) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.schedule_rounded,
            size: 48,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            isId ? 'Belum ada workflow' : 'No workflows yet',
            style: TextStyle(fontSize: 15, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(
            isId
                ? 'Buat workflow untuk menjalankan tugas otomatis'
                : 'Create workflows to run automated tasks',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () async {
              final result = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => const WorkflowTemplatesScreen(),
                ),
              );
              if (result == true) _load();
            },
            icon: const Icon(Icons.auto_awesome_rounded, size: 16),
            label: Text(isId ? 'Pilih dari Template' : 'Pick a Template'),
            style: OutlinedButton.styleFrom(
              foregroundColor: cs.primary,
              side: BorderSide(color: cs.primary.withValues(alpha: 0.4)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(
    WorkflowModel wf,
    ColorScheme cs,
    MeowExtras extras,
    bool isId,
  ) {
    final selected = _selectedIds.contains(wf.id);
    return GestureDetector(
      onTap: () => _onCardTap(wf),
      onLongPress: () => _onCardLongPress(wf),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? cs.primary.withValues(alpha: 0.08) : extras.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? cs.primary : extras.subtleBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (_selectionMode) ...[
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected
                    ? cs.primary
                    : cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    wf.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        wf.trigger.type == TriggerType.schedule
                            ? Icons.schedule_rounded
                            : Icons.loop_rounded,
                        size: 13,
                        color: cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        wf.trigger.summary,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        _notifIcon(wf.notification.style),
                        size: 13,
                        color: cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _notifLabel(wf.notification.style, isId),
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  if (wf.lastRun != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      '${isId ? "Terakhir:" : "Last run:"} ${_formatTime(wf.lastRun!)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!_selectionMode) ...[
              const SizedBox(width: 8),
              Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: wf.enabled,
                  onChanged: (_) => _toggle(wf),
                  activeTrackColor: cs.primary,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _notifIcon(NotifStyle style) {
    switch (style) {
      case NotifStyle.silent:
        return Icons.notifications_off_rounded;
      case NotifStyle.alarm:
        return Icons.alarm_rounded;
      case NotifStyle.normal:
        return Icons.notifications_rounded;
    }
  }

  String _notifLabel(NotifStyle style, bool isId) {
    switch (style) {
      case NotifStyle.silent:
        return isId ? 'Senyap' : 'Silent';
      case NotifStyle.alarm:
        return 'Alarm';
      case NotifStyle.normal:
        return 'Normal';
    }
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    return '$d/$mo $h:$m';
  }
}
