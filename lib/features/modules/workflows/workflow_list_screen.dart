import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../settings/data/app_language_provider.dart';
import 'workflow_model.dart';
import 'workflow_repository.dart';
import 'workflow_editor_screen.dart';

/// Lists all workflows with toggle, edit, and delete.
class WorkflowListScreen extends ConsumerStatefulWidget {
  const WorkflowListScreen({super.key});

  @override
  ConsumerState<WorkflowListScreen> createState() => _WorkflowListScreenState();
}

class _WorkflowListScreenState extends ConsumerState<WorkflowListScreen> {
  final WorkflowRepository _repo = WorkflowRepository();
  List<WorkflowModel> _workflows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _repo.list();
    if (mounted) setState(() { _workflows = list; _loading = false; });
  }

  Future<void> _toggle(WorkflowModel wf) async {
    await _repo.toggle(wf.id, !wf.enabled);
    _load();
  }

  Future<void> _delete(WorkflowModel wf) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Hapus Workflow?'),
        content: Text('Workflow "${wf.title}" akan dihapus permanen.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hapus', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _repo.delete(wf.id);
      _load();
    }
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

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final langPref = ref.watch(appLanguageProvider);
    final isId = resolveLanguageCode(langPref) == 'id';

    return Scaffold(
      appBar: AppBar(
        title: Text(isId ? 'Workflows' : 'Workflows'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      floatingActionButton: FloatingActionButton(
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
                  itemBuilder: (_, i) => _buildCard(_workflows[i], cs, extras, isId),
                ),
    );
  }

  Widget _buildEmpty(ColorScheme cs, MeowExtras extras, bool isId) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule_rounded, size: 48, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
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
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(WorkflowModel wf, ColorScheme cs, MeowExtras extras, bool isId) {
    return GestureDetector(
      onTap: () => _openEditor(workflow: wf),
      onLongPress: () => _delete(wf),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: extras.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: extras.subtleBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    wf.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                Switch(
                  value: wf.enabled,
                  onChanged: (_) => _toggle(wf),
                  activeTrackColor: cs.primary,
                ),
              ],
            ),
            const SizedBox(height: 4),
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
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
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
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
            if (wf.lastRun != null) ...[
              const SizedBox(height: 8),
              Text(
                '${isId ? "Terakhir:" : "Last run:"} ${_formatTime(wf.lastRun!)}',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
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
