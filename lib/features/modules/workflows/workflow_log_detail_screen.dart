import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../agents/data/agent_repository.dart';
import '../../settings/data/app_language_provider.dart';
import 'workflow_editor_screen.dart';
import 'workflow_model.dart';
import 'workflow_repository.dart';

/// Detail page for a single workflow execution log entry.
class WorkflowLogDetailScreen extends ConsumerWidget {
  const WorkflowLogDetailScreen({super.key, required this.execution});

  final WorkflowExecution execution;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final extras = context.extras;
    final langPref = ref.watch(appLanguageProvider);
    final isId = resolveLanguageCode(langPref) == 'id';
    final agents = ref.watch(agentListProvider);
    final agent = agents.where((a) => a.id == execution.agentId).firstOrNull;

    final isSuccess = execution.status == 'success';

    return Scaffold(
      appBar: AppBar(
        title: Text(isId ? 'Detail Log' : 'Log Detail'),
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            // Status banner.
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isSuccess
                    ? Colors.green.withValues(alpha: 0.12)
                    : Colors.red.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSuccess
                      ? Colors.green.withValues(alpha: 0.3)
                      : Colors.red.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isSuccess
                        ? Icons.check_circle_rounded
                        : Icons.error_rounded,
                    color: isSuccess ? Colors.green : Colors.red,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          execution.workflowTitle,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isSuccess
                              ? (isId ? 'Berhasil dijalankan' : 'Successfully executed')
                              : (isId ? 'Gagal dijalankan' : 'Execution failed'),
                          style: TextStyle(
                            fontSize: 13,
                            color: isSuccess ? Colors.green : Colors.red,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Metadata section.
            _sectionLabel(isId ? 'Informasi' : 'Information', cs),
            const SizedBox(height: 10),
            _infoCard(extras, [
              _infoRow(
                Icons.smart_toy_outlined,
                isId ? 'Agent' : 'Agent',
                agent?.name ?? execution.agentId,
                cs,
              ),
              _infoRow(
                Icons.schedule_rounded,
                isId ? 'Waktu Eksekusi' : 'Executed At',
                _formatDateTime(execution.executedAt, isId),
                cs,
              ),
              _infoRow(
                Icons.timer_outlined,
                isId ? 'Durasi' : 'Duration',
                _formatDuration(execution.durationMs ?? 0),
                cs,
              ),
            ]),
            const SizedBox(height: 20),

            // Open workflow button (right after Informasi).
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _openWorkflow(context, isId),
                icon: const Icon(Icons.edit_note_rounded, size: 20),
                label: Text(
                  isId ? 'Buka Workflow' : 'Open Workflow',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: cs.primary,
                  side: BorderSide(color: cs.primary.withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Result section.
            _sectionLabel(
              isSuccess
                  ? (isId ? 'Hasil' : 'Result')
                  : (isId ? 'Error' : 'Error'),
              cs,
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: extras.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: extras.subtleBorder),
              ),
              child: SelectableText(
                execution.result,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: cs.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Runtime timeline section.
            if (execution.events.isNotEmpty) ...[
              _sectionLabel(
                isId ? 'Runtime' : 'Runtime',
                cs,
              ),
              const SizedBox(height: 10),
              _timelineCard(execution.events, extras, cs, isId),
              const SizedBox(height: 12),
            ],
          ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text, ColorScheme cs) => Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: cs.onSurfaceVariant,
        ),
      );

  Widget _infoCard(MeowExtras extras, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: extras.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: extras.subtleBorder),
      ),
      child: Column(children: children),
    );
  }

  Widget _infoRow(IconData icon, String label, String value, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _timelineCard(
    List<WorkflowExecutionEvent> events,
    MeowExtras extras,
    ColorScheme cs,
    bool isId,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: extras.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: extras.subtleBorder),
      ),
      child: Column(
        children: [
          for (var i = 0; i < events.length; i++)
            _timelineRow(events[i], i == events.length - 1, cs, extras),
        ],
      ),
    );
  }

  Widget _timelineRow(
    WorkflowExecutionEvent event,
    bool isLast,
    ColorScheme cs,
    MeowExtras extras,
  ) {
    final accent = _eventColor(event.type, cs);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Dot + connector.
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Column(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.4),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: extras.subtleBorder,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 12, bottom: isLast ? 12 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(_eventIcon(event.type), size: 14, color: accent),
                      const SizedBox(width: 6),
                      Text(
                        _eventLabel(event.type),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: accent,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _formatTime(event.createdAt),
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    event.message,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _eventIcon(String type) {
    switch (type) {
      case 'state_change':
        return Icons.sync_rounded;
      case 'llm_decision':
        return Icons.psychology_rounded;
      case 'tool_call':
        return Icons.build_rounded;
      case 'tool_result':
        return Icons.check_circle_outline_rounded;
      case 'error':
        return Icons.error_outline_rounded;
      case 'final_response':
        return Icons.flag_rounded;
      default:
        return Icons.info_outline_rounded;
    }
  }

  Color _eventColor(String type, ColorScheme cs) {
    switch (type) {
      case 'tool_call':
        return Colors.amber;
      case 'tool_result':
        return Colors.green;
      case 'error':
        return Colors.red;
      case 'final_response':
        return cs.primary;
      case 'llm_decision':
        return Colors.purpleAccent;
      default:
        return cs.onSurfaceVariant;
    }
  }

  String _eventLabel(String type) {
    switch (type) {
      case 'state_change':
        return 'STATE';
      case 'llm_decision':
        return 'LLM';
      case 'tool_call':
        return 'TOOL CALL';
      case 'tool_result':
        return 'TOOL RESULT';
      case 'error':
        return 'ERROR';
      case 'final_response':
        return 'RESPONSE';
      default:
        return type.toUpperCase();
    }
  }

  String _formatTime(DateTime dt) {
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  String _formatDateTime(DateTime dt, bool isId) {
    const monthsId = [
      'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun',
      'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des',
    ];
    const monthsEn = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final months = isId ? monthsId : monthsEn;
    final dd = dt.day.toString().padLeft(2, '0');
    final mon = months[dt.month - 1];
    final yyyy = dt.year;
    final hh = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$dd $mon $yyyy, $hh:$min';
  }

  String _formatDuration(int ms) {
    if (ms < 1000) return '${ms}ms';
    final seconds = ms / 1000;
    if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
    final minutes = seconds / 60;
    return '${minutes.toStringAsFixed(1)}m';
  }

  Future<void> _openWorkflow(BuildContext context, bool isId) async {
    final repo = WorkflowRepository();
    final workflow = await repo.read(execution.workflowId);
    if (!context.mounted) return;
    if (workflow == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isId
              ? 'Workflow sudah dihapus.'
              : 'Workflow has been deleted.'),
        ),
      );
      return;
    }
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => WorkflowEditorScreen(workflow: workflow),
      ),
    );
  }
}
