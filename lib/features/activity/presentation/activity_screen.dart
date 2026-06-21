import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../agents/data/agent_model.dart';
import '../../agents/data/agent_repository.dart';
import '../../modules/workflows/workflow_log_detail_screen.dart';
import '../../modules/workflows/workflow_model.dart';
import '../../modules/workflows/workflow_repository.dart';
import '../../modules/workflows/workflow_run_ledger.dart';
import '../../settings/data/app_language_provider.dart';

/// Activity screen — shows workflow execution history with agent filter.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  static const _allAgentsFilter = '__all_agents__';

  final WorkflowRepository _repo = WorkflowRepository();
  final WorkflowRunDatabase _runDb = WorkflowRunDatabase();
  List<WorkflowExecution> _history = [];
  List<WorkflowRunLedger> _running = [];
  bool _loading = true;
  String? _selectedAgentId; // null = all agents
  Timer? _liveTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _startLivePolling();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    super.dispose();
  }

  void _startLivePolling() {
    _liveTimer?.cancel();
    _liveTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _loadRunning();
    });
  }

  Future<void> _loadRunning() async {
    try {
      final running = await _runDb.listRunning();
      if (!mounted) return;
      if (_running.length != running.length ||
          running.any((r) => !_running.any((e) => e.runId == r.runId))) {
        setState(() => _running = running);
      } else if (running.isNotEmpty) {
        // Update step progress.
        setState(() => _running = running);
      }
    } catch (_) {}
  }

  Future<void> _load() async {
    await _loadRunning();
    final history = await _repo.getHistory(
      agentId: _selectedAgentId,
      limit: 100,
    );
    if (mounted) {
      setState(() {
        _history = history;
        _loading = false;
      });
    }
  }

  void _onAgentChanged(String? agentId) {
    setState(() {
      _selectedAgentId = agentId;
      _loading = true;
    });
    _load();
  }

  Future<void> _clearAll(AppStrings s, List<AgentModel> agents) async {
    final scopedAgent = _selectedAgentId == null
        ? null
        : agents.where((a) => a.id == _selectedAgentId).firstOrNull;
    final scopeLabel = scopedAgent != null
        ? s.activityForAgent(scopedAgent.name)
        : s.activityFromAll;

    final confirmed = await showMeowConfirmDialog(
      context,
      strings: s,
      title: s.activityClearTitle,
      message: s.activityClearBody(scopeLabel),
      confirmLabel: s.activityClear,
      cancelLabel: s.cancel,
    );
    if (!confirmed) return;

    final removed = await _repo.clearAllHistory(agentId: _selectedAgentId);
    if (!mounted) return;
    setState(() {
      _history = [];
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(s.activityCleared(removed)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));
    final agents = ref.watch(agentListProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.activity),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: s.activityOptions,
            enabled: _history.isNotEmpty,
            onSelected: (v) {
              if (v == 'clear') _clearAll(s, agents);
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_sweep_outlined,
                      size: 18,
                      color: cs.error,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      s.activityClearAll,
                      style: TextStyle(color: cs.error),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Agent filter dropdown.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: MeowDropdown<String>(
                value: _selectedAgentId ?? _allAgentsFilter,
                presentation: MeowDropdownPresentation.menu,
                searchable: false,
                dense: true,
                options: [
                  MeowDropdownOption<String>(
                    value: _allAgentsFilter,
                    label: s.activityAllAgents,
                    prefix: const MeowAgentIcon(size: 22, radius: 8),
                  ),
                  ...agents.map(
                    (agent) => MeowDropdownOption<String>(
                      value: agent.id,
                      label: agent.name,
                      prefix: MeowAgentIcon(
                        agent: agent,
                        size: 22,
                        radius: 8,
                      ),
                    ),
                  ),
                ],
                onChanged: (value) =>
                    _onAgentChanged(value == _allAgentsFilter ? null : value),
              ),
            ),
            const SizedBox(height: 4),
            // Content.
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      color: cs.primary,
                      child: (_history.isEmpty && _running.isEmpty)
                          ? LayoutBuilder(
                              builder: (ctx, constraints) =>
                                  SingleChildScrollView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: constraints.maxHeight,
                                  ),
                                  child: _buildEmpty(cs, s),
                                ),
                              ),
                            )
                          : ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding:
                                  const EdgeInsets.fromLTRB(16, 8, 16, 16),
                              itemCount: _running.length +
                                  (_running.isNotEmpty ? 1 : 0) +
                                  _history.length,
                              itemBuilder: (_, i) {
                                // Running section header.
                                if (_running.isNotEmpty && i == 0) {
                                  return _buildRunningHeader(cs, s);
                                }
                                final offset = _running.isNotEmpty ? 1 : 0;
                                // Running entries.
                                if (i - offset < _running.length) {
                                  return _buildRunningEntry(
                                    _running[i - offset],
                                    cs,
                                    extras,
                                    agents,
                                    s,
                                  );
                                }
                                // History entries.
                                final histIdx = i - offset - _running.length;
                                return _buildEntry(
                                  _history[histIdx],
                                  cs,
                                  extras,
                                  agents,
                                  s,
                                );
                              },
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRunningHeader(ColorScheme cs, AppStrings s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          _PulsingDot(color: cs.primary),
          const SizedBox(width: 8),
          Text(
            s.activityRunningNow,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.primary,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRunningEntry(
    WorkflowRunLedger run,
    ColorScheme cs,
    MeowExtras extras,
    List<AgentModel> agents,
    AppStrings s,
  ) {
    final agentName =
        agents
            .where((a) => a.id == run.agentId)
            .map((a) => a.name)
            .firstOrNull ??
        run.agentId;

    final elapsed = DateTime.now().difference(run.startedAt);
    final elapsedStr = _formatElapsed(elapsed);

    final currentStep = run.currentStepIndex + 1;
    final totalSteps = run.steps.length;
    final progress = totalSteps > 0 ? currentStep / totalSteps : 0.0;

    // Current step's goal (truncated).
    final activeStep = run.stepAt(run.currentStepIndex);
    final stepLabel = activeStep?.mainGoal ?? '';
    final stepPreview =
        stepLabel.length > 80 ? '${stepLabel.substring(0, 80)}…' : stepLabel;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              cs.primary.withValues(alpha: 0.06),
              cs.primary.withValues(alpha: 0.02),
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: title + running badge.
            Row(
              children: [
                Icon(
                  Icons.play_circle_rounded,
                  size: 14,
                  color: cs.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    run.workflowTitle,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    s.activityRunning,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: cs.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Progress bar.
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: cs.primary.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation(cs.primary),
              ),
            ),
            const SizedBox(height: 8),
            // Current step preview.
            if (stepPreview.isNotEmpty)
              Text(
                stepPreview,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant,
                  height: 1.4,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            if (stepPreview.isNotEmpty) const SizedBox(height: 8),
            // Footer: agent + step counter + elapsed.
            Row(
              children: [
                Icon(
                  Icons.smart_toy_outlined,
                  size: 11,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 4),
                Text(
                  agentName,
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
                const Spacer(),
                Text(
                  s.activityRunningStep(currentStep, totalSteps),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: cs.primary.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.timer_outlined,
                  size: 11,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 3),
                Text(
                  elapsedStr,
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(ColorScheme cs, AppStrings s) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.history_rounded,
            size: 44,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            s.noActivityYet,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            s.activityEmptyDesc,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildEntry(
    WorkflowExecution entry,
    ColorScheme cs,
    MeowExtras extras,
    List<AgentModel> agents,
    AppStrings s,
  ) {
    final agentName =
        agents
            .where((a) => a.id == entry.agentId)
            .map((a) => a.name)
            .firstOrNull ??
        entry.agentId;

    final statusColor = _statusColor(entry.status);
    final statusIcon = _statusIcon(entry.status);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: extras.card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute(
              builder: (_) => WorkflowLogDetailScreen(execution: entry),
            ),
          ),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: extras.subtleBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header: title + status.
                Row(
                  children: [
                    Icon(statusIcon, size: 14, color: statusColor),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        entry.workflowTitle,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _statusLabel(entry.status, s),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: statusColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Result preview.
                Text(
                  entry.result,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    height: 1.4,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                // Footer: agent + time + duration.
                Row(
                  children: [
                    Icon(
                      Icons.smart_toy_outlined,
                      size: 11,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      agentName,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatTime(entry.executedAt),
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                    if (entry.durationMs != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${(entry.durationMs! / 1000).toStringAsFixed(1)}s',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'success':
        return Colors.green;
      case 'failed':
        return Colors.redAccent;
      case 'retry':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'success':
        return Icons.check_circle_rounded;
      case 'failed':
        return Icons.error_rounded;
      case 'retry':
        return Icons.refresh_rounded;
      default:
        return Icons.circle_outlined;
    }
  }

  String _statusLabel(String status, AppStrings s) {
    switch (status) {
      case 'success':
        return s.activitySuccess;
      case 'failed':
        return s.activityFailed;
      case 'retry':
        return s.activityRetry;
      default:
        return status;
    }
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    return '$d/$mo $h:$m';
  }

  String _formatElapsed(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    }
    return '${d.inSeconds}s';
  }
}

/// A small pulsing dot indicator for the "Running Now" section header.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});
  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.4),
              blurRadius: 6,
            ),
          ],
        ),
      ),
    );
  }
}
