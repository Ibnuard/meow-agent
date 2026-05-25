import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../agents/data/agent_repository.dart';
import '../../settings/data/app_language_provider.dart';
import 'workflow_model.dart';

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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
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
          ],
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
}
