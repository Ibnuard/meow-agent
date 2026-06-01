import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../agents/data/agent_model.dart';
import '../../agents/data/agent_repository.dart';
import '../../modules/workflows/workflow_log_detail_screen.dart';
import '../../modules/workflows/workflow_model.dart';
import '../../modules/workflows/workflow_repository.dart';
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
  List<WorkflowExecution> _history = [];
  bool _loading = true;
  String? _selectedAgentId; // null = all agents

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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

  Future<void> _clearAll(bool isId, List<AgentModel> agents) async {
    final s = AppStrings(isId ? 'id' : 'en');
    final scopedAgent = _selectedAgentId == null
        ? null
        : agents.where((a) => a.id == _selectedAgentId).firstOrNull;
    final scopeLabel = scopedAgent != null
        ? s.activityForAgent(scopedAgent.name)
        : s.activityFromAll;

    final confirmed = await showMeowConfirmDialog(
      context,
      isId: isId,
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
    final isId = resolveLanguageCode(langPref) == 'id';
    final s = AppStrings(isId ? 'id' : 'en');
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
              if (v == 'clear') _clearAll(isId, agents);
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
            // History list.
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _history.isEmpty
                  ? _buildEmpty(cs, isId)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemCount: _history.length,
                      itemBuilder: (_, i) =>
                          _buildEntry(_history[i], cs, extras, agents, isId),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(ColorScheme cs, bool isId) {
    final s = AppStrings(isId ? 'id' : 'en');
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
    bool isId,
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
                        _statusLabel(entry.status, isId),
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

  String _statusLabel(String status, bool isId) {
    final s = AppStrings(isId ? 'id' : 'en');
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
}
