import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../agents/data/agent_repository.dart';
import '../../settings/data/app_language_provider.dart';
import '../../settings/data/llm_debug_provider.dart';
import 'workflow_editor_screen.dart';
import 'workflow_model.dart';
import 'workflow_repository.dart';

/// Detail page for a single workflow execution log entry.
class WorkflowLogDetailScreen extends ConsumerStatefulWidget {
  const WorkflowLogDetailScreen({super.key, required this.execution});

  final WorkflowExecution execution;

  @override
  ConsumerState<WorkflowLogDetailScreen> createState() =>
      _WorkflowLogDetailScreenState();
}

class _WorkflowLogDetailScreenState
    extends ConsumerState<WorkflowLogDetailScreen> {
  bool _resultExpanded = false;

  WorkflowExecution get execution => widget.execution;

  /// Max characters before truncation in collapsed mode.
  static const _resultPreviewLength = 300;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final langPref = ref.watch(appLanguageProvider);
    final isId = resolveLanguageCode(langPref) == 'id';
    final s = AppStrings(isId ? 'id' : 'en');
    final agents = ref.watch(agentListProvider);
    final agent = agents.where((a) => a.id == execution.agentId).firstOrNull;
    final isDevMode = ref.watch(llmDebugModeProvider);

    final isSuccess = execution.status == 'success';

    return Scaffold(
      appBar: AppBar(title: Text(s.wfLogDetailTitle)),
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
                                ? s.wfLogSuccess
                                : s.wfLogFailed,
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
              _sectionLabel(s.wfLogInformation, cs),
              const SizedBox(height: 10),
              _infoCard(extras, [
                _infoRow(
                  Icons.smart_toy_outlined,
                  'Agent',
                  agent?.name ?? execution.agentId,
                  cs,
                ),
                _infoRow(
                  Icons.schedule_rounded,
                  s.wfLogExecutedAt,
                  _formatDateTime(execution.executedAt, isId),
                  cs,
                ),
                _infoRow(
                  Icons.timer_outlined,
                  s.wfLogDuration,
                  _formatDuration(execution.durationMs ?? 0),
                  cs,
                ),
              ]),
              const SizedBox(height: 20),

              // Open workflow button (right after Informasi).
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _openWorkflow(context, s),
                  icon: const Icon(Icons.edit_note_rounded, size: 20),
                  label: Text(
                    s.wfLogOpenWorkflow,
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

              // Result section — formatted with step separators + expand/collapse.
              _sectionLabel(
                isSuccess ? s.result : 'Error',
                cs,
              ),
              const SizedBox(height: 10),
              _buildResultCard(cs, extras, s),
              const SizedBox(height: 24),

              // Runtime timeline section.
              if (execution.events.isNotEmpty) ...[
                _sectionLabel('Runtime', cs),
                const SizedBox(height: 10),
                _buildTimelineSection(
                  execution.events,
                  extras,
                  cs,
                  s,
                  isDevMode,
                ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ─── Result Section ─────────────────────────────────────────────────────────

  /// Build a formatted result card that shows step results with separators.
  /// Includes expand/collapse when content is long.
  Widget _buildResultCard(ColorScheme cs, MeowExtras extras, AppStrings s) {
    final formattedResult = _formatStepResults();
    final isLong = formattedResult.length > _resultPreviewLength;
    final displayText = (!_resultExpanded && isLong)
        ? '${formattedResult.substring(0, _resultPreviewLength)}…'
        : formattedResult;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: extras.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: extras.subtleBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GptMarkdown(
            displayText,
            style: TextStyle(color: cs.onSurface, fontSize: 14, height: 1.5),
          ),
          if (isLong) ...[
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => setState(() => _resultExpanded = !_resultExpanded),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _resultExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _resultExpanded
                        ? s.wfLogCollapse
                        : s.wfLogShowMore,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.primary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Format step results into a readable concatenated string.
  /// For multi-step workflows, each step gets a labeled section.
  String _formatStepResults() {
    final steps = execution.stepResults;
    if (steps.isEmpty) {
      // Single-step workflow — return raw result.
      return execution.result;
    }

    final buf = StringBuffer();
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final emoji = step.status == 'success'
          ? '✅'
          : step.status == 'skipped'
          ? '⏭️'
          : '❌';
      buf.writeln('$emoji Langkah ${i + 1}: ${step.stepId}');
      buf.writeln('─' * 30);
      buf.writeln(step.result.trim());
      if (i < steps.length - 1) {
        buf.writeln();
      }
    }
    return buf.toString().trim();
  }

  // ─── Runtime Timeline Section ───────────────────────────────────────────────

  /// Build the timeline section. In dev mode, show all events.
  /// In normal mode, only show human-friendly events (narrative, step_start,
  /// final_response, error).
  Widget _buildTimelineSection(
    List<WorkflowExecutionEvent> events,
    MeowExtras extras,
    ColorScheme cs,
    AppStrings s,
    bool isDevMode,
  ) {
    final filtered = isDevMode ? events : _filterHumanEvents(events);

    if (filtered.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: extras.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: extras.subtleBorder),
        ),
        child: Text(
          s.wfLogNoRuntimeDetails,
          style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
        ),
      );
    }

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
          for (var i = 0; i < filtered.length; i++)
            _timelineRow(
              filtered[i],
              i == filtered.length - 1,
              cs,
              extras,
              s,
              isDevMode,
            ),
        ],
      ),
    );
  }

  /// Filter events to only human-friendly ones for non-dev mode.
  List<WorkflowExecutionEvent> _filterHumanEvents(
    List<WorkflowExecutionEvent> events,
  ) {
    const humanTypes = {
      'narrative',
      'step_start',
      'step_handoff',
      'step_skipped',
      'step_retry',
      'step_failure_skipped',
      'chain_stopped',
      'final_response',
      'error',
    };
    return events.where((e) => humanTypes.contains(e.type)).toList();
  }

  Widget _timelineRow(
    WorkflowExecutionEvent event,
    bool isLast,
    ColorScheme cs,
    MeowExtras extras,
    AppStrings s,
    bool isDevMode,
  ) {
    final accent = _eventColor(event.type, cs);
    // In non-dev mode, show friendlier labels.
    final label = isDevMode
        ? _eventLabel(event.type)
        : _friendlyLabel(event.type, s);
    final icon = isDevMode ? _eventIcon(event.type) : _friendlyIcon(event.type);
    // In non-dev mode, strip technical prefixes like "[Step 1]".
    final message = isDevMode ? event.message : _humanizeMessage(event, s);

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
                      Icon(icon, size: 14, color: accent),
                      const SizedBox(width: 6),
                      Text(
                        label,
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
                    message,
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

  // ─── Event Helpers ──────────────────────────────────────────────────────────

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
      case 'step_handoff':
        return Icons.swap_horiz_rounded;
      default:
        return Icons.info_outline_rounded;
    }
  }

  IconData _friendlyIcon(String type) {
    switch (type) {
      case 'narrative':
        return Icons.chat_bubble_outline_rounded;
      case 'step_start':
        return Icons.play_circle_outline_rounded;
      case 'step_handoff':
        return Icons.swap_horiz_rounded;
      case 'step_skipped':
        return Icons.skip_next_rounded;
      case 'step_retry':
        return Icons.refresh_rounded;
      case 'chain_stopped':
        return Icons.stop_circle_outlined;
      case 'error':
        return Icons.warning_amber_rounded;
      case 'final_response':
        return Icons.check_circle_outline_rounded;
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
      case 'narrative':
        return cs.primary;
      case 'step_start':
        return cs.onSurfaceVariant;
      case 'step_handoff':
        return Colors.tealAccent;
      case 'chain_stopped':
        return Colors.red;
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
      case 'step_handoff':
        return 'HANDOFF';
      default:
        return type.toUpperCase();
    }
  }

  String _friendlyLabel(String type, AppStrings s) {
    switch (type) {
      case 'narrative':
        return s.wfLogProcessLabel;
      case 'step_start':
        return s.wfLogStepLabel;
      case 'step_handoff':
        return s.wfLogHandoffLabel;
      case 'step_skipped':
        return s.wfLogSkippedLabel;
      case 'step_retry':
        return s.wfLogRetryLabel;
      case 'step_failure_skipped':
        return s.wfLogContinueLabel;
      case 'chain_stopped':
        return s.wfLogStoppedLabel;
      case 'error':
        return s.wfLogFailedLabel;
      case 'final_response':
        return s.wfLogDoneLabel;
      default:
        return type.toUpperCase();
    }
  }

  /// Make event messages more human-friendly by stripping technical prefixes
  /// and reformatting step references.
  String _humanizeMessage(WorkflowExecutionEvent event, AppStrings s) {
    var msg = event.message;
    // Strip "[Step N] " prefix.
    msg = msg.replaceAll(RegExp(r'^\[Step \d+\]\s*'), '');
    // Strip "[Step N retry] " prefix.
    msg = msg.replaceAll(RegExp(r'^\[Step \d+ retry\]\s*'), '');
    // Reformat "Starting step N: id" to friendlier form.
    final startMatch = RegExp(r'^Starting step (\d+): (.+)$').firstMatch(msg);
    if (startMatch != null) {
      final num = int.parse(startMatch.group(1)!);
      return s.wfLogStartingStep(num, startMatch.group(2)!);
    }
    // Reformat chain stopped.
    if (msg.contains('Chain stopped at step')) {
      final stepNum = RegExp(r'step (\d+)').firstMatch(msg)?.group(1) ?? '?';
      return s.wfLogProcessStopped(int.parse(stepNum));
    }
    return msg;
  }

  // ─── Formatting Helpers ─────────────────────────────────────────────────────

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
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
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

  String _formatTime(DateTime dt) {
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  String _formatDateTime(DateTime dt, bool isId) {
    const monthsId = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agu',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    const monthsEn = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
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

  Future<void> _openWorkflow(BuildContext context, AppStrings s) async {
    final repo = WorkflowRepository();
    final workflow = await repo.read(execution.workflowId);
    if (!context.mounted) return;
    if (workflow == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.wfLogDeleted),
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
