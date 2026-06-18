import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../agents/data/agent_model.dart';
import '../../agents/data/agent_repository.dart';
import '../../settings/data/app_language_provider.dart';
import 'workflow_builtin_vars.dart';
import 'workflow_model.dart';
import 'workflow_repository.dart';
import 'workflow_scheduler.dart';
import 'workflow_templates.dart';
import '../web/data/api_config.dart';
import '../web/data/api_store_repository.dart';

/// Create or edit a workflow.
class WorkflowEditorScreen extends ConsumerStatefulWidget {
  const WorkflowEditorScreen({super.key, this.workflow, this.template});
  final WorkflowModel? workflow;
  final WorkflowTemplate? template;

  @override
  ConsumerState<WorkflowEditorScreen> createState() =>
      _WorkflowEditorScreenState();
}

class _WorkflowEditorScreenState extends ConsumerState<WorkflowEditorScreen> {
  final _repo = WorkflowRepository();
  final _titleCtrl = TextEditingController();
  TextEditingController _promptCtrl = _VariableTextEditingController();
  final _keywordCtrl = TextEditingController();
  final Map<String, TextEditingController> _stepPromptCtrls = {};

  bool get _isEdit => widget.workflow != null;

  String? _selectedAgentId;
  TriggerType _triggerType = TriggerType.schedule;
  EventTriggerKind _eventKind = EventTriggerKind.batteryLow;
  TimeOfDay _time = const TimeOfDay(hour: 8, minute: 0);
  List<int> _selectedDays = [1, 2, 3, 4, 5, 6, 7];
  int _intervalMinutes = 60;
  NotifStyle _notifStyle = NotifStyle.normal;
  bool _sendToChat = false;
  bool _allowSensitive = false;
  WorkflowPriority _priority = WorkflowPriority.normal;
  int _timeoutSeconds = 300;
  List<WorkflowStep> _steps = [];
  String? _templateId;
  bool _advancedSettingsExpanded = false;

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      _loadFromWorkflow(widget.workflow!);
    } else if (widget.template != null) {
      _loadFromTemplate(widget.template!);
    }
  }

  void _loadFromWorkflow(WorkflowModel wf) {
    _titleCtrl.text = wf.title;
    _promptCtrl.text = WorkflowBuiltInVars.migrateLegacyPlaceholders(wf.prompt);
    _selectedAgentId = wf.agentId;
    _triggerType = wf.trigger.type;
    _eventKind = wf.trigger.eventKind ?? EventTriggerKind.batteryLow;
    _keywordCtrl.text = (wf.trigger.eventParams?['keyword'] as String?) ?? '';
    _time = TimeOfDay(
      hour: wf.trigger.hour ?? 8,
      minute: wf.trigger.minute ?? 0,
    );
    _selectedDays = List<int>.from(
      wf.trigger.daysOfWeek ?? [1, 2, 3, 4, 5, 6, 7],
    );
    _intervalMinutes = _snapIntervalToOption(wf.trigger.intervalMinutes ?? 60);
    _notifStyle = wf.notification.style;
    _sendToChat = wf.sendToChat;
    _allowSensitive = wf.allowSensitive;
    _priority = wf.priority;
    _timeoutSeconds = _snapTimeoutToOption(wf.timeoutSeconds);
    _steps = wf.steps
        .map(
          (s) => WorkflowStep(
            id: s.id,
            prompt: WorkflowBuiltInVars.migrateLegacyPlaceholders(s.prompt),
            agentId: s.agentId,
            condition: s.condition,
            onFailure: s.onFailure,
            timeoutSeconds: s.timeoutSeconds,
          ),
        )
        .toList();
    _templateId = wf.templateId;
  }

  void _loadFromTemplate(WorkflowTemplate tpl) {
    final langCode = resolveLanguageCode(ref.read(appLanguageProvider));
    _titleCtrl.text = langCode == 'id' ? tpl.titleId : tpl.title;
    _promptCtrl.text = WorkflowBuiltInVars.migrateLegacyPlaceholders(
      tpl.defaultPrompt,
    );
    _templateId = tpl.id;
    if (tpl.defaultTrigger != null) {
      final t = tpl.defaultTrigger!;
      _triggerType = t.type;
      _eventKind = t.eventKind ?? EventTriggerKind.batteryLow;
      _keywordCtrl.text = (t.eventParams?['keyword'] as String?) ?? '';
      if (t.hour != null) {
        _time = TimeOfDay(hour: t.hour!, minute: t.minute ?? 0);
      }
      _selectedDays = List<int>.from(t.daysOfWeek ?? [1, 2, 3, 4, 5, 6, 7]);
      _intervalMinutes = _snapIntervalToOption(t.intervalMinutes ?? 60);
    }
    _steps = tpl.defaultSteps
        .map(
          (s) => WorkflowStep(
            id: s.id,
            prompt: WorkflowBuiltInVars.migrateLegacyPlaceholders(s.prompt),
            agentId: s.agentId,
            condition: s.condition,
            onFailure: s.onFailure,
            timeoutSeconds: s.timeoutSeconds,
          ),
        )
        .toList();
    _priority = tpl.defaultPriority;
    _timeoutSeconds = _snapTimeoutToOption(tpl.defaultTimeoutSeconds);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _promptCtrl.dispose();
    _keywordCtrl.dispose();
    for (final ctrl in _stepPromptCtrls.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final isId = Localizations.localeOf(context).languageCode == 'id';
    final sSave = AppStrings(isId ? 'id' : 'en');
    if (_selectedAgentId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            sSave.workflowSelectAgentFirst,
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (_titleCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(sSave.wfTitleRequired),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (_steps.isEmpty && _promptCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isId
                ? 'Prompt atau langkah tidak boleh kosong.'
                : 'Prompt or steps are required.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (_steps.isNotEmpty &&
        _steps.any((step) => (step.agentId ?? _selectedAgentId) == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isId
                ? 'Setiap langkah harus punya agent.'
                : 'Each step must have an agent.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    Map<String, dynamic>? eventParams;
    if (_triggerType == TriggerType.event) {
      switch (_eventKind) {
        case EventTriggerKind.notificationKeyword:
          eventParams = {'keyword': _keywordCtrl.text.trim()};
          break;
        default:
          eventParams = null;
      }
    }

    final trigger = TriggerConfig(
      type: _triggerType,
      hour: _triggerType == TriggerType.schedule ? _time.hour : null,
      minute: _triggerType == TriggerType.schedule ? _time.minute : null,
      daysOfWeek: _triggerType == TriggerType.schedule ? _selectedDays : null,
      intervalMinutes: _triggerType == TriggerType.interval
          ? _intervalMinutes
          : null,
      eventKind: _triggerType == TriggerType.event ? _eventKind : null,
      eventParams: eventParams,
    );

    final notif = NotifConfig(style: _notifStyle, showResult: true);

    // Normalize per-step timeouts to the workflow-level value so the UI's
    // timeout control is the single source of truth. The runner reads
    // step.timeoutSeconds for multi-step workflows; without this sync, an
    // editor change to the workflow-level timeout would have no effect on
    // existing steps that were created with stale defaults (e.g. 60s).
    final normalizedSteps = _steps
        .map(
          (s) => WorkflowStep(
            id: s.id,
            prompt: s.prompt,
            agentId: s.agentId ?? _selectedAgentId,
            condition: s.condition,
            onFailure: s.onFailure,
            timeoutSeconds: _timeoutSeconds,
          ),
        )
        .toList();

    if (_isEdit) {
      final updated = widget.workflow!.copyWith(
        agentId: _selectedAgentId,
        title: _titleCtrl.text.trim(),
        prompt: _promptCtrl.text.trim(),
        trigger: trigger,
        notification: notif,
        sendToChat: _sendToChat,
        allowSensitive: _allowSensitive,
        priority: _priority,
        timeoutSeconds: _timeoutSeconds,
        steps: normalizedSteps,
        variables: const {}, // legacy field; built-ins handle everything now.
        templateId: _templateId,
      );
      await _repo.update(updated);
      await WorkflowScheduler.cancel(updated);
      await WorkflowScheduler.schedule(updated);
    } else {
      final workflow = WorkflowModel(
        id: 'wf_${const Uuid().v4().substring(0, 8)}',
        agentId: _selectedAgentId!,
        title: _titleCtrl.text.trim(),
        prompt: _promptCtrl.text.trim(),
        trigger: trigger,
        notification: notif,
        sendToChat: _sendToChat,
        allowSensitive: _allowSensitive,
        enabled: true,
        priority: _priority,
        timeoutSeconds: _timeoutSeconds,
        steps: normalizedSteps,
        variables: const {}, // legacy field; built-ins handle everything now.
        templateId: _templateId,
        createdAt: DateTime.now(),
      );
      final success = await _repo.create(workflow);
      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(sSave.wfMaxWorkflows)),
        );
        return;
      }
      await WorkflowScheduler.schedule(workflow);
    }

    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _confirmDelete(AppStrings s) async {
    if (widget.workflow == null) return;
    final wf = widget.workflow!;
    final confirm = await showMeowConfirmDialog(
      context,
      strings: s,
      title: s.workflowDeleteTitle,
      message: s.workflowDeleteMessage(wf.title),
      confirmLabel: s.workflowDelete,
      cancelLabel: s.workflowCancel,
    );
    if (!confirm) return;
    await WorkflowScheduler.cancel(wf);
    await _repo.delete(wf.id);
    if (mounted) Navigator.pop(context, true);
  }

  void _addStep() {
    setState(() {
      _steps.add(
        WorkflowStep(
          id: 'step_${_steps.length + 1}',
          prompt: '',
          agentId: _selectedAgentId,
          timeoutSeconds: _timeoutSeconds,
        ),
      );
    });
  }

  /// Snap any loaded timeout to the nearest valid chip option so the UI
  /// always has a selected state. Falls back to 300s (5m) for stored values
  /// below the smallest option.
  static int _snapTimeoutToOption(int stored) {
    const options = [180, 300, 600, 900];
    if (options.contains(stored)) return stored;
    // Pick the smallest option >= stored, else default to 5m.
    for (final opt in options) {
      if (opt >= stored) return opt;
    }
    return 300;
  }

  /// Snap any loaded interval to the nearest valid chip option so the UI
  /// always has a selected state. Falls back to 60m (1h) for values that
  /// don't match any option.
  static int _snapIntervalToOption(int stored) {
    const options = [15, 30, 60, 120, 180, 360, 720, 1440];
    if (options.contains(stored)) return stored;
    // Pick the smallest option >= stored, else default to 1h.
    for (final opt in options) {
      if (opt >= stored) return opt;
    }
    return 60;
  }

  void _removeStep(int index) {
    final removed = _steps[index];
    _stepPromptCtrls.remove(removed.id)?.dispose();
    setState(() => _steps.removeAt(index));
  }

  TextEditingController _stepPromptController(WorkflowStep step) {
    final existing = _stepPromptCtrls[step.id];
    if (existing != null) {
      if (existing.text != step.prompt && existing.selection.baseOffset < 0) {
        existing.text = step.prompt;
      }
      return existing;
    }
    return _stepPromptCtrls[step.id] = _VariableTextEditingController(
      text: step.prompt,
    );
  }

  void _updateStep(int index, WorkflowStep updated) {
    setState(() => _steps[index] = updated);
  }

  @override
  Widget build(BuildContext context) {
    _ensureVariablePromptController();
    final cs = context.cs;
    final extras = context.extras;
    final langPref = ref.watch(appLanguageProvider);
    final isId = resolveLanguageCode(langPref) == 'id';
    final s = AppStrings(isId ? 'id' : 'en');
    final agents = ref.watch(agentListProvider);

    if (_selectedAgentId == null && agents.isNotEmpty) {
      _selectedAgentId = agents.first.id;
    }

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _isEdit ? s.workflowEditTitle : s.workflowNewTitle,
          ),
          actions: [
            if (_isEdit)
              IconButton(
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                ),
                tooltip: s.workflowDeleteTooltip,
                onPressed: () => _confirmDelete(s),
              ),
          ],
        ),
        body: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_steps.isEmpty) ...[
                _sectionLabel(s.workflowSectionAgent, cs),
                const SizedBox(height: 8),
                _buildAgentPicker(agents, s),
              ] else ...[
                _multiAgentInfoCard(cs, extras, s),
              ],
              const SizedBox(height: 20),

              _sectionLabel(s.workflowSectionTitle, cs),
              const SizedBox(height: 8),
              _buildInput(
                _titleCtrl,
                s.workflowTitleHint,
                cs,
                extras,
              ),
              const SizedBox(height: 20),

              _sectionLabel(s.workflowSectionTrigger, cs),
              const SizedBox(height: 8),
              _buildTriggerSelector(cs, s),
              const SizedBox(height: 16),

              if (_triggerType == TriggerType.schedule) ...[
                _buildTimePicker(cs, extras, s),
                const SizedBox(height: 12),
                _buildDaySelector(cs, isId),
              ] else if (_triggerType == TriggerType.interval) ...[
                _buildIntervalPicker(cs, isId),
              ] else ...[
                _buildEventTriggerConfig(cs, extras, s),
              ],
              const SizedBox(height: 24),

              // Mode toggle: single prompt vs chained steps.
              Row(
                children: [
                  _sectionLabel(s.workflowSectionMode, cs),
                  const Spacer(),
                  Text(
                    _steps.isEmpty
                        ? s.workflowSinglePrompt
                        : s.workflowStepsCount(_steps.length),
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              if (_steps.isEmpty) ...[
                _sectionLabel('Prompt', cs),
                const SizedBox(height: 8),
                _buildVariableAwareInput(
                  _promptCtrl,
                  isId
                      ? 'Apa yang harus agent lakukan...'
                      : 'What should the agent do...',
                  cs,
                  extras,
                  maxLines: 4,
                  s: s,
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _addStep,
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: Text(
                    isId
                        ? 'Konversi ke Multi-Langkah'
                        : 'Convert to Multi-Step',
                  ),
                ),
              ] else ...[
                ..._buildStepList(cs, extras, s, agents),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _addStep,
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: Text(s.workflowAddStep),
                ),
              ],
              const SizedBox(height: 24),

              // ─── Variables (moved above Trigger) ───────────────────
              _buildVariablesSection(cs, extras, s),
              const SizedBox(height: 24),

              _buildAdvancedSettings(cs, extras, s),
              const SizedBox(height: 20),

              _buildToggle(
                s.workflowSendToChat,
                _sendToChat,
                (v) => setState(() => _sendToChat = v),
                cs,
              ),
              const SizedBox(height: 14),
              _buildToggleWithDesc(
                s.workflowAllowSensitive,
                s.wfAllowSensitiveDesc,
                _allowSensitive,
                (v) => setState(() => _allowSensitive = v),
                cs,
              ),
              const SizedBox(height: 32),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cs.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    _isEdit ? s.workflowSave : s.workflowCreate,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdvancedSettings(ColorScheme cs, MeowExtras extras, AppStrings s) {
    return Container(
      decoration: BoxDecoration(
        color: extras.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: extras.subtleBorder),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(
              () => _advancedSettingsExpanded = !_advancedSettingsExpanded,
            ),
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(
                children: [
                  Icon(Icons.tune_rounded, size: 18, color: cs.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      s.workflowMoreSettings,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  Text(
                    '${_notifLabel(_notifStyle, s)} · ${_priorityLabel(_priority, s)} · ${_timeoutLabel(_timeoutSeconds)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: _advancedSettingsExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: 20,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Divider(color: extras.subtleBorder, height: 1),
                  const SizedBox(height: 14),
                  _sectionLabel(s.workflowNotification, cs),
                  const SizedBox(height: 8),
                  _buildNotifSelector(cs, s),
                  const SizedBox(height: 18),
                  _sectionLabel(s.workflowPriority, cs),
                  const SizedBox(height: 8),
                  _buildPrioritySelector(cs, s),
                  const SizedBox(height: 18),
                  _sectionLabel(s.workflowTimeout, cs),
                  const SizedBox(height: 8),
                  _buildTimeoutSelector(cs, s),
                ],
              ),
            ),
            crossFadeState: _advancedSettingsExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 180),
            firstCurve: Curves.easeOutCubic,
            secondCurve: Curves.easeOutCubic,
            sizeCurve: Curves.easeOutCubic,
          ),
        ],
      ),
    );
  }

  String _timeoutLabel(int seconds) {
    if (seconds >= 60) return '${seconds ~/ 60}m';
    return '${seconds}s';
  }

  Widget _multiAgentInfoCard(ColorScheme cs, MeowExtras extras, AppStrings s) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.primary.withValues(alpha: 0.10)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.groups_2_outlined, size: 18, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.workflowMultiAgent,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  s.isId
                      ? 'Setiap langkah wajib punya agent. Semua langkah otomatis memakai agent default dulu, lalu bisa diganti per langkah.'
                      : 'Each step requires an agent. Steps use the default agent first, then can be changed per step.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.82),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Step List Builders ─────────────────────────────────────────────────────

  List<Widget> _buildStepList(
    ColorScheme cs,
    MeowExtras extras,
    AppStrings s,
    List<AgentModel> agents,
  ) {
    return List.generate(_steps.length, (i) {
      final step = _steps[i];
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: extras.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: extras.subtleBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: cs.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.workflowStepLabel(i),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                  onPressed: () => _removeStep(i),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildStepAgentPicker(step, i, agents, s),
            const SizedBox(height: 10),
            _buildVariableAwareInput(
              _stepPromptController(step),
              s.isId
                  ? 'Apa yang harus dilakukan di langkah ini?'
                  : 'What should happen in this step?',
              cs,
              extras,
              maxLines: 4,
              minLines: 3,
              s: s,
              onChanged: (v) {
                _updateStep(
                  i,
                  WorkflowStep(
                    id: step.id,
                    prompt: v,
                    agentId: step.agentId,
                    condition: step.condition,
                    onFailure: step.onFailure,
                    timeoutSeconds: step.timeoutSeconds,
                  ),
                );
              },
            ),
            const SizedBox(height: 10),
            // Condition preset dropdown.
            if (i > 0) ...[
              Text(
                s.isId
                    ? 'Kapan langkah ini berjalan?'
                    : 'When does this step run?',
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              _buildConditionDropdown(step, i, cs, extras, s),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                Text(
                  s.workflowOnFailure,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                const SizedBox(width: 8),
                ...StepFailureAction.values.map(
                  (a) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      onTap: () => _updateStep(
                        i,
                        WorkflowStep(
                          id: step.id,
                          prompt: step.prompt,
                          agentId: step.agentId,
                          condition: step.condition,
                          onFailure: a,
                          timeoutSeconds: step.timeoutSeconds,
                        ),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: step.onFailure == a
                              ? cs.primary.withValues(alpha: 0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: step.onFailure == a
                                ? cs.primary
                                : cs.onSurfaceVariant.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          _failureActionLabel(a, s),
                          style: TextStyle(
                            fontSize: 10,
                            color: step.onFailure == a
                                ? cs.primary
                                : cs.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    });
  }

  Widget _buildStepAgentPicker(
    WorkflowStep step,
    int index,
    List<AgentModel> agents,
    AppStrings s,
  ) {
    final fallbackAgentId = _selectedAgentId ?? agents.firstOrNull?.id;
    final effectiveAgentId = step.agentId ?? fallbackAgentId;
    if (step.agentId == null && effectiveAgentId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final current = _steps[index];
        if (current.agentId != null) return;
        _updateStep(
          index,
          WorkflowStep(
            id: current.id,
            prompt: current.prompt,
            agentId: effectiveAgentId,
            condition: current.condition,
            onFailure: current.onFailure,
            timeoutSeconds: current.timeoutSeconds,
          ),
        );
      });
    }

    return MeowDropdown<String>(
      value: effectiveAgentId,
      presentation: MeowDropdownPresentation.sheet,
      sheetTitle: s.workflowChooseStepAgent,
      sheetSubtitle: s.isId
          ? 'Langkah ini akan dijalankan oleh agent yang dipilih.'
          : 'This step will run using the selected agent.',
      searchHint: s.workflowSearchAgent,
      emptyText: s.workflowNoAgents,
      searchable: agents.length > 6,
      dense: true,
      options: agents
          .map(
            (agent) => MeowDropdownOption<String>(
              value: agent.id,
              label: agent.name.trim().isEmpty
                  ? s.workflowUntitledAgent
                  : agent.name.trim(),
              subtitle: s.isId
                  ? 'Agent untuk langkah ini'
                  : 'Agent for this step',
              prefix: MeowAgentIcon(agent: agent),
              searchText: agent.name,
            ),
          )
          .toList(),
      onChanged: (agentId) {
        if (agentId == null) return;
        _updateStep(
          index,
          WorkflowStep(
            id: step.id,
            prompt: step.prompt,
            agentId: agentId,
            condition: step.condition,
            onFailure: step.onFailure,
            timeoutSeconds: step.timeoutSeconds,
          ),
        );
      },
    );
  }

  String _failureActionLabel(StepFailureAction a, AppStrings s) {
    switch (a) {
      case StepFailureAction.stop:
        return s.workflowFailureStop;
      case StepFailureAction.skip:
        return s.workflowFailureSkip;
      case StepFailureAction.retry:
        return s.workflowFailureRetry;
    }
  }

  Widget _buildConditionDropdown(
    WorkflowStep step,
    int index,
    ColorScheme cs,
    MeowExtras extras,
    AppStrings s,
  ) {
    final presets = _ConditionPreset.all(s);
    final currentValue = step.condition;
    final selected = presets.firstWhere(
      (p) => p.value == currentValue,
      orElse: () => presets.first,
    );
    return MeowDropdown<_ConditionPreset>(
      value: selected,
      presentation: MeowDropdownPresentation.menu,
      searchable: false,
      dense: true,
      options: presets
          .map(
            (preset) => MeowDropdownOption(value: preset, label: preset.label),
          )
          .toList(),
      onChanged: (value) {
        if (value == null) return;
        _updateStep(
          index,
          WorkflowStep(
            id: step.id,
            prompt: step.prompt,
            agentId: step.agentId,
            condition: value.value,
            onFailure: step.onFailure,
            timeoutSeconds: step.timeoutSeconds,
          ),
        );
      },
    );
  }

  // ─── Variables Section ──────────────────────────────────────────────────────

  Widget _buildVariablesSection(ColorScheme cs, MeowExtras extras, AppStrings s) {
    final langCode = s.code;
    final visibleVars = _visibleBuiltIns();
    final previewVars = visibleVars.take(6).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _sectionLabel(
              s.workflowBuiltinVars,
              cs,
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _showBuiltInVariableSheet(cs, extras, s),
              icon: const Icon(Icons.auto_awesome_rounded, size: 14),
              label: Text(
                s.workflowViewAll,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          s.isId
              ? 'Tap variabel untuk menyisipkan ke prompt. Nilainya otomatis diisi saat workflow berjalan.'
              : 'Tap a variable to insert it. Values are filled automatically when the workflow runs.',
          style: TextStyle(
            fontSize: 11,
            color: cs.onSurfaceVariant.withValues(alpha: 0.62),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: extras.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: extras.subtleBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: previewVars
                    .map((v) => _builtInChip(v, cs, langCode))
                    .toList(),
              ),
              if (visibleVars.length > previewVars.length) ...[
                const SizedBox(height: 10),
                InkWell(
                  onTap: () => _showBuiltInVariableSheet(cs, extras, s),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Icon(
                          Icons.expand_more_rounded,
                          size: 16,
                          color: cs.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          s.isId
                              ? '+${visibleVars.length - previewVars.length} variabel lain'
                              : '+${visibleVars.length - previewVars.length} more variables',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  List<BuiltInVariable> _visibleBuiltIns() {
    final statics = kWorkflowBuiltInVariables.where((v) {
      switch (v.category) {
        case BuiltInCategory.step:
          return _steps.isNotEmpty;
        case BuiltInCategory.triggerNotification:
          return _triggerType == TriggerType.event &&
              _eventKind == EventTriggerKind.notificationKeyword;
        case BuiltInCategory.triggerAppOpen:
          return _triggerType == TriggerType.event &&
              _eventKind == EventTriggerKind.appOpened;
        case BuiltInCategory.triggerBattery:
          return _triggerType == TriggerType.event &&
              (_eventKind == EventTriggerKind.batteryLow ||
                  _eventKind == EventTriggerKind.batteryAbove ||
                  _eventKind == EventTriggerKind.batteryFull ||
                  _eventKind == EventTriggerKind.chargingStart ||
                  _eventKind == EventTriggerKind.chargingStop);
        case BuiltInCategory.time:
        case BuiltInCategory.identity:
        case BuiltInCategory.action:
          return true;
      }
    }).toList();
    // Dynamic @step1..@step{N-1} grow with the number of steps. The final
    // step's output is never referenceable, so stepResultVariables emits
    // exactly the useful ones (empty for < 2 steps).
    return [...statics, ...stepResultVariables(_steps.length)];
  }

  Widget _builtInChip(
    BuiltInVariable variable,
    ColorScheme cs,
    String langCode,
  ) {
    return InkWell(
      onTap: () => _insertBuiltInVariable(variable.placeholder),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: cs.primary.withValues(alpha: 0.22)),
        ),
        child: Text(
          variable.placeholder,
          style: TextStyle(
            fontSize: 11,
            color: cs.primary,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  void _insertBuiltInVariable(String placeholder) {
    final controller = _promptCtrl;
    final selection = controller.selection;
    if (!selection.isValid) {
      Clipboard.setData(ClipboardData(text: placeholder));
      return;
    }
    final text = controller.text;
    final start = selection.start.clamp(0, text.length);
    final end = selection.end.clamp(0, text.length);
    controller.text = text.replaceRange(start, end, placeholder);
    final pos = start + placeholder.length;
    controller.selection = TextSelection.collapsed(offset: pos);
    setState(() {});
  }

  Future<void> _showBuiltInVariableSheet(
    ColorScheme cs,
    MeowExtras extras,
    AppStrings s,
  ) async {
    final vars = _visibleBuiltIns();
    final grouped = <BuiltInCategory, List<BuiltInVariable>>{};
    for (final v in vars) {
      grouped.putIfAbsent(v.category, () => []).add(v);
    }

    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        final maxSheetHeight = media.size.height * 0.78;
        final bottomPadding = media.viewPadding.bottom + 12;

        return Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(maxHeight: maxSheetHeight),
            margin: const EdgeInsets.only(left: 10, right: 10),
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              border: Border(top: BorderSide(color: extras.inputBorder)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 30,
                  spreadRadius: -14,
                  offset: const Offset(0, -10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              child: Padding(
                padding: EdgeInsets.only(bottom: bottomPadding),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Drag handle
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        width: 38,
                        height: 4,
                        decoration: BoxDecoration(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.24),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),

                    // Header: title + subtitle + close
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.workflowBuiltinVars,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    color: cs.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  s.isId
                                      ? 'Tap untuk menyisipkan ke prompt utama.'
                                      : 'Tap to insert into the main prompt.',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.35,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            icon: Icon(
                              Icons.close_rounded,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Content
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                        children: [
                          // ─── @api: row (same style as other vars) ──────────
                          Padding(
                            padding: const EdgeInsets.only(left: 4, top: 4, bottom: 8),
                            child: Text(
                              'API',
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurface,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _insertBuiltInVariable('@api:');
                            },
                            borderRadius: BorderRadius.circular(14),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF06B6D4).withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(color: const Color(0xFF06B6D4).withValues(alpha: 0.18)),
                                    ),
                                    child: const Text(
                                      '@api:',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF06B6D4),
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      s.isId
                                          ? 'Panggil API tersimpan (ketik @api: lalu nama API)'
                                          : 'Call stored API (type @api: then API name)',
                                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),

                          // ─── Built-in variable categories ───────────────────
                          ...grouped.entries.map((entry) {
                            return Theme(
                              data: Theme.of(ctx).copyWith(
                                dividerColor: Colors.transparent,
                              ),
                              child: ExpansionTile(
                                initiallyExpanded: true,
                                tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                                childrenPadding: const EdgeInsets.only(
                                  left: 4,
                                  right: 4,
                                  bottom: 8,
                                ),
                                title: Text(
                                  entry.key.labelFor(s.code),
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: cs.onSurface,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                children: entry.value
                                    .map((v) => _builtInSheetRow(v, cs, s.code))
                                    .toList(),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _builtInSheetRow(
    BuiltInVariable variable,
    ColorScheme cs,
    String langCode,
  ) {
    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        _insertBuiltInVariable(variable.placeholder);
      },
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
              ),
              child: Text(
                variable.placeholder,
                style: TextStyle(
                  fontSize: 11,
                  color: cs.primary,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                variable.descriptionFor(langCode),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Trigger Builders ───────────────────────────────────────────────────────

  Widget _buildTriggerSelector(ColorScheme cs, AppStrings s) {
    return Wrap(
      spacing: 8,
      children: [
        _chip(
          s.workflowSchedule,
          _triggerType == TriggerType.schedule,
          () => setState(() => _triggerType = TriggerType.schedule),
          cs,
        ),
        _chip(
          'Interval',
          _triggerType == TriggerType.interval,
          () => setState(() => _triggerType = TriggerType.interval),
          cs,
        ),
        _chip(
          s.workflowEvent,
          _triggerType == TriggerType.event,
          () => setState(() => _triggerType = TriggerType.event),
          cs,
        ),
      ],
    );
  }

  Widget _buildEventTriggerConfig(
    ColorScheme cs,
    MeowExtras extras,
    AppStrings s,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(s.workflowEventType, cs),
        const SizedBox(height: 8),
        MeowDropdown<EventTriggerKind>(
          value: _eventKind,
          presentation: MeowDropdownPresentation.sheet,
          sheetTitle: s.workflowChooseEventType,
          sheetSubtitle: s.isId
              ? 'Workflow akan berjalan otomatis saat event ini terjadi.'
              : 'Workflow runs automatically when this event happens.',
          searchHint: s.workflowSearchEvent,
          emptyText: s.workflowNoEvents,
          searchable: true,
          dense: true,
          options: EventTriggerKind.values
              .map(
                (kind) => MeowDropdownOption<EventTriggerKind>(
                  value: kind,
                  label: _eventKindLabel(kind, s),
                  subtitle: _eventKindSubtitle(kind, s),
                  searchText: _eventKindSearchText(kind),
                ),
              )
              .toList(),
          onChanged: (value) =>
              setState(() => _eventKind = value ?? EventTriggerKind.batteryLow),
        ),
        const SizedBox(height: 12),
        if (_eventKind == EventTriggerKind.notificationKeyword) ...[
          _sectionLabel(s.workflowKeyword, cs),
          const SizedBox(height: 8),
          _buildInput(
            _keywordCtrl,
            s.workflowKeywordHint,
            cs,
            extras,
          ),
          const SizedBox(height: 10),
          _notificationTriggerInfoCard(cs, extras, s),
        ],
      ],
    );
  }

  Widget _notificationTriggerInfoCard(
    ColorScheme cs,
    MeowExtras extras,
    AppStrings s,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.primary.withValues(alpha: 0.10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                s.workflowTriggerRequired,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _infoBullet(s.wfNotifyPermRequired, cs),
          const SizedBox(height: 7),
          _infoBullet(s.wfModuleDisabled, cs),
        ],
      ),
    );
  }

  Widget _infoBullet(String text, ColorScheme cs) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 6),
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.85),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: cs.onSurfaceVariant.withValues(alpha: 0.82),
            ),
          ),
        ),
      ],
    );
  }

  String _eventKindLabel(EventTriggerKind k, AppStrings s) {
    switch (k) {
      case EventTriggerKind.batteryLow:
        return s.wfEventBatteryLow;
      case EventTriggerKind.batteryAbove:
        return s.wfEventBatteryHigh;
      case EventTriggerKind.batteryFull:
        return s.wfEventBatteryFull;
      case EventTriggerKind.chargingStart:
        return s.wfEventChargingStart;
      case EventTriggerKind.chargingStop:
        return s.wfEventChargingStop;
      case EventTriggerKind.notificationKeyword:
        return s.wfEventNotifKeyword;
      case EventTriggerKind.appOpened:
        return s.wfEventAppOpened;
      case EventTriggerKind.wifiConnected:
        return s.wfEventWifiConnected;
      case EventTriggerKind.wifiDisconnected:
        return s.wfEventWifiDisconnected;
    }
  }

  String _eventKindSubtitle(EventTriggerKind k, AppStrings s) {
    switch (k) {
      case EventTriggerKind.batteryLow:
        return s.wfEventBatteryLowSub;
      case EventTriggerKind.batteryAbove:
        return s.wfEventBatteryHighSub;
      case EventTriggerKind.batteryFull:
        return s.wfEventBatteryFullSub;
      case EventTriggerKind.chargingStart:
        return s.wfEventChargingStartSub;
      case EventTriggerKind.chargingStop:
        return s.wfEventChargingStopSub;
      case EventTriggerKind.notificationKeyword:
        return s.wfEventNotifKeywordSub;
      case EventTriggerKind.appOpened:
        return s.wfEventAppOpenedSub;
      case EventTriggerKind.wifiConnected:
        return s.wfEventWifiConnectedSub;
      case EventTriggerKind.wifiDisconnected:
        return s.wfEventWifiDisconnectedSub;
    }
  }

  String _eventKindSearchText(EventTriggerKind k) {
    switch (k) {
      case EventTriggerKind.batteryLow:
        return 'battery baterai low rendah below dibawah 50';
      case EventTriggerKind.batteryAbove:
        return 'battery baterai high above diatas 50';
      case EventTriggerKind.batteryFull:
        return 'battery baterai full penuh 100';
      case EventTriggerKind.chargingStart:
        return 'charge charging charger mulai plug plugged';
      case EventTriggerKind.chargingStop:
        return 'charge charging stop berhenti unplug unplugged';
      case EventTriggerKind.notificationKeyword:
        return 'notification notif notifikasi keyword kata kunci';
      case EventTriggerKind.appOpened:
        return 'app aplikasi opened dibuka package';
      case EventTriggerKind.wifiConnected:
        return 'wifi connected tersambung terhubung internet';
      case EventTriggerKind.wifiDisconnected:
        return 'wifi disconnected terputus putus internet';
    }
  }

  Widget _buildPrioritySelector(ColorScheme cs, AppStrings s) {
    return Wrap(
      spacing: 8,
      children: WorkflowPriority.values.map((p) {
        return _chip(
          _priorityLabel(p, s),
          _priority == p,
          () => setState(() => _priority = p),
          cs,
        );
      }).toList(),
    );
  }

  String _priorityLabel(WorkflowPriority p, AppStrings s) {
    switch (p) {
      case WorkflowPriority.low:
        return s.workflowPriorityLow;
      case WorkflowPriority.normal:
        return 'Normal';
      case WorkflowPriority.high:
        return s.workflowPriorityHigh;
      case WorkflowPriority.critical:
        return s.workflowPriorityCritical;
    }
  }

  Widget _buildTimeoutSelector(ColorScheme cs, AppStrings s) {
    final options = [180, 300, 600, 900];
    final labels = ['3m', '5m', '10m', '15m'];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(options.length, (i) {
        final selected = _timeoutSeconds == options[i];
        return GestureDetector(
          onTap: () => setState(() => _timeoutSeconds = options[i]),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? cs.primary.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? cs.primary
                    : cs.onSurfaceVariant.withValues(alpha: 0.2),
              ),
            ),
            child: Text(
              labels[i],
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ),
        );
      }),
    );
  }

  // ─── Common UI Builders (preserved) ─────────────────────────────────────────

  Widget _sectionLabel(String text, ColorScheme cs) => Text(
    text,
    style: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: cs.onSurfaceVariant,
    ),
  );

  void _ensureVariablePromptController() {
    if (_promptCtrl is _VariableTextEditingController) return;
    final old = _promptCtrl;
    final migrated = _VariableTextEditingController()
      ..text = old.text
      ..selection = old.selection;
    _promptCtrl = migrated;
    old.dispose();
  }

  Widget _buildVariableAwareInput(
    TextEditingController ctrl,
    String hint,
    ColorScheme cs,
    MeowExtras extras, {
    int maxLines = 1,
    int? minLines,
    ValueChanged<String>? onChanged,
    required AppStrings s,
  }) {
    final langCode = s.code;

    return StatefulBuilder(
      builder: (context, localSetState) {
        final trigger = _activeVariableTrigger(ctrl);
        final isApiQuery = trigger != null && trigger.query.startsWith('api:');
        final suggestions = trigger == null
            ? const <BuiltInVariable>[]
            : isApiQuery
                ? const <BuiltInVariable>[]
                : _visibleBuiltIns()
                      .where(
                        (v) => v.key.toLowerCase().contains(
                          trigger.query.toLowerCase(),
                        ),
                      )
                      .take(6)
                      .toList();

        // API suggestions when user types @api: or @api
        final showApiHint = trigger != null &&
            !isApiQuery &&
            'api'.contains(trigger.query.toLowerCase()) &&
            trigger.query.isNotEmpty;
        final apiSuggestions = isApiQuery
            ? _getApiSuggestions(trigger.query.substring(4))
            : const <ApiConfig>[];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              minLines: minLines,
              maxLines: maxLines,
              inputFormatters: const [_VariableTokenDeleteFormatter()],
              onChanged: (value) {
                onChanged?.call(value);
                localSetState(() {});
              },
              style: TextStyle(fontSize: 14, color: cs.onSurface),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                filled: true,
                fillColor: extras.inputFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.18),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.18),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(color: cs.primary),
                ),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: maxLines > 1 ? 16 : 12,
                ),
              ),
            ),
            if (trigger != null && suggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: extras.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.workflowInsertVariable,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: suggestions.map((v) {
                        return ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 280),
                          child: InkWell(
                            onTap: () {
                              _replaceVariableTrigger(ctrl, trigger, v.key);
                              onChanged?.call(ctrl.text);
                              localSetState(() {});
                            },
                            borderRadius: BorderRadius.circular(999),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: cs.primary.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: cs.primary.withValues(alpha: 0.24),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    v.key,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: cs.primary,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      v.descriptionFor(langCode),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ],

            // Show @api: hint when user types @a, @ap, @api
            if (showApiHint) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () {
                  _replaceVariableTriggerRaw(ctrl, trigger, 'api:');
                  localSetState(() {});
                },
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF06B6D4).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFF06B6D4).withValues(alpha: 0.24)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_rounded, size: 12, color: Color(0xFF06B6D4)),
                      const SizedBox(width: 5),
                      Text(
                        '@api:',
                        style: TextStyle(
                          fontSize: 11,
                          color: const Color(0xFF06B6D4),
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        s.wfApiCallLabel,
                        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            // API suggestions when query starts with api:
            if (isApiQuery && apiSuggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: extras.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF06B6D4).withValues(alpha: 0.18)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.wfApiSelectLabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...apiSuggestions.map((api) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: InkWell(
                          onTap: () {
                            final safeName = api.name.replaceAll(RegExp(r'\s+'), '_');
                            _replaceVariableTrigger(ctrl, trigger, 'api:$safeName');
                            onChanged?.call(ctrl.text);
                            localSetState(() {});
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF06B6D4).withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFF06B6D4).withValues(alpha: 0.15)),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: _methodColor(api.method).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    api.method,
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800,
                                      color: _methodColor(api.method),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    api.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: cs.onSurface,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  static Color _methodColor(String method) {
    switch (method.toUpperCase()) {
      case 'GET': return const Color(0xFF22C55E);
      case 'POST': return const Color(0xFF3B82F6);
      case 'PUT': return const Color(0xFFF59E0B);
      case 'PATCH': return const Color(0xFF8B5CF6);
      case 'DELETE': return const Color(0xFFEF4444);
      default: return const Color(0xFF64748B);
    }
  }

  List<ApiConfig> _cachedApis = [];
  DateTime? _lastApiLoad;

  List<ApiConfig> _getApiSuggestions(String query) {
    // Refresh cache every 5 seconds
    final now = DateTime.now();
    if (_lastApiLoad == null || now.difference(_lastApiLoad!).inSeconds > 5) {
      _lastApiLoad = now;
      ApiStoreRepository.instance.list().then((apis) {
        _cachedApis = apis.toList();
      });
    }
    if (query.isEmpty) return _cachedApis.take(8).toList();
    return _cachedApis
        .where((a) => a.name.toLowerCase().contains(query.toLowerCase()))
        .take(8)
        .toList();
  }

  /// Like _replaceVariableTrigger but doesn't add a trailing space (for @api: prefix).
  void _replaceVariableTriggerRaw(
    TextEditingController ctrl,
    _VariableTrigger trigger,
    String key,
  ) {
    final text = ctrl.text;
    final end = trigger.end.clamp(0, text.length);
    final replacement = '@$key';
    ctrl.text = text.replaceRange(trigger.start, end, replacement);
    final pos = trigger.start + replacement.length;
    ctrl.selection = TextSelection.collapsed(offset: pos);
  }

  _VariableTrigger? _activeVariableTrigger(TextEditingController ctrl) {
    final selection = ctrl.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    final cursor = selection.baseOffset;
    if (cursor < 1 || cursor > ctrl.text.length) return null;
    final text = ctrl.text;
    final before = text.substring(0, cursor);
    final at = before.lastIndexOf('@');
    if (at < 0) return null;
    // Word boundary on the left so emails like foo@bar.com don't trigger.
    if (at > 0) {
      final prev = before[at - 1];
      if (RegExp(r'[\w@]').hasMatch(prev)) return null;
    }
    final query = before.substring(at + 1);
    // Allow colon in the query only when it's the 'api:' prefix pattern.
    // Stop suggestions if the user typed another non-word character.
    if (query.isNotEmpty) {
      final cleaned = query.startsWith('api:') ? query.substring(4) : query;
      if (cleaned.isNotEmpty && RegExp(r'[^\w]').hasMatch(cleaned)) return null;
      // Also reject if colon appears but doesn't form 'api:'
      if (query.contains(':') && !query.startsWith('api:')) return null;
    }
    return _VariableTrigger(at, cursor, query);
  }

  void _replaceVariableTrigger(
    TextEditingController ctrl,
    _VariableTrigger trigger,
    String key,
  ) {
    final text = ctrl.text;
    final end = trigger.end.clamp(0, text.length);
    // Append a trailing space so the cursor lands OUTSIDE the @key token,
    // killing the active trigger and dismissing the suggestion strip. Skip
    // when the next char is already whitespace to avoid doubling.
    final nextChar = end < text.length ? text[end] : '';
    final needsSpace = nextChar.isEmpty || !RegExp(r'\s').hasMatch(nextChar);
    final replacement = needsSpace ? '@$key ' : '@$key';
    ctrl.text = text.replaceRange(trigger.start, end, replacement);
    final pos = trigger.start + replacement.length;
    ctrl.selection = TextSelection.collapsed(offset: pos);
  }

  Widget _buildInput(
    TextEditingController ctrl,
    String hint,
    ColorScheme cs,
    MeowExtras extras, {
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: ctrl,
      maxLines: maxLines,
      onChanged: onChanged,
      style: TextStyle(fontSize: 14, color: cs.onSurface),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
        filled: true,
        fillColor: extras.card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: extras.subtleBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: extras.subtleBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: cs.primary),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
    );
  }

  Widget _buildAgentPicker(List<AgentModel> agents, AppStrings s) {
    final selectedValue = agents.any((a) => a.id == _selectedAgentId)
        ? _selectedAgentId
        : null;

    return MeowDropdown<String>(
      value: selectedValue,
      enabled: agents.isNotEmpty,
      hint: agents.isEmpty
          ? s.workflowNoAgentsYet
          : s.workflowChooseAgent,
      sheetTitle: s.workflowChooseAgentTitle,
      searchHint: s.workflowSearchAgentsLong,
      emptyText: s.workflowNoAgentsFound,
      options: agents
          .map(
            (agent) => MeowDropdownOption<String>(
              value: agent.id,
              label: agent.name.trim().isEmpty
                  ? s.workflowUntitledAgent
                  : agent.name.trim(),
              prefix: MeowAgentIcon(agent: agent),
              searchText: '${agent.providerId} ${agent.maxContextLength}',
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value == null) return;
        setState(() => _selectedAgentId = value);
      },
    );
  }

  Widget _buildTimePicker(ColorScheme cs, MeowExtras extras, AppStrings s) {
    return GestureDetector(
      onTap: _pickTime,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: extras.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: extras.subtleBorder),
        ),
        child: Row(
          children: [
            Icon(Icons.access_time_rounded, size: 18, color: cs.primary),
            const SizedBox(width: 10),
            Text(
              _time.format(context),
              style: TextStyle(fontSize: 14, color: cs.onSurface),
            ),
            const Spacer(),
            Text(
              s.workflowChange,
              style: TextStyle(fontSize: 12, color: cs.primary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDaySelector(ColorScheme cs, bool isId) {
    const dayLabelsId = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
    const dayLabelsEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final labels = isId ? dayLabelsId : dayLabelsEn;

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: List.generate(7, (i) {
        final day = i + 1;
        final selected = _selectedDays.contains(day);
        return GestureDetector(
          onTap: () => setState(() {
            if (selected) {
              _selectedDays.remove(day);
            } else {
              _selectedDays.add(day);
            }
          }),
          child: Container(
            width: 40,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? cs.primary.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected
                    ? cs.primary
                    : cs.onSurfaceVariant.withValues(alpha: 0.2),
              ),
            ),
            child: Text(
              labels[i],
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildIntervalPicker(ColorScheme cs, bool isId) {
    final options = [15, 30, 60, 120, 180, 360, 720, 1440];
    final labels = ['15m', '30m', '1h', '2h', '3h', '6h', '12h', '24h'];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(options.length, (i) {
        final selected = _intervalMinutes == options[i];
        return GestureDetector(
          onTap: () => setState(() => _intervalMinutes = options[i]),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? cs.primary.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? cs.primary
                    : cs.onSurfaceVariant.withValues(alpha: 0.2),
              ),
            ),
            child: Text(
              labels[i],
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ),
        );
      }),
    );
  }

  String _notifLabel(NotifStyle style, AppStrings s) {
    switch (style) {
      case NotifStyle.silent:
        return s.workflowSilent;
      case NotifStyle.normal:
        return 'Normal';
      case NotifStyle.alarm:
        return 'Alarm';
    }
  }

  Widget _buildNotifSelector(ColorScheme cs, AppStrings s) {
    return Row(
      children: [
        _chip(
          s.workflowSilent,
          _notifStyle == NotifStyle.silent,
          () => setState(() => _notifStyle = NotifStyle.silent),
          cs,
        ),
        const SizedBox(width: 8),
        _chip(
          'Normal',
          _notifStyle == NotifStyle.normal,
          () => setState(() => _notifStyle = NotifStyle.normal),
          cs,
        ),
        const SizedBox(width: 8),
        _chip(
          'Alarm',
          _notifStyle == NotifStyle.alarm,
          () => setState(() => _notifStyle = NotifStyle.alarm),
          cs,
        ),
      ],
    );
  }

  Widget _buildToggle(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
    ColorScheme cs,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: cs.onSurface)),
        Switch(
          value: value,
          onChanged: onChanged,
          activeTrackColor: cs.primary,
        ),
      ],
    );
  }

  Widget _buildToggleWithDesc(
    String label,
    String description,
    bool value,
    ValueChanged<bool> onChanged,
    ColorScheme cs,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Switch(
          value: value,
          onChanged: onChanged,
          activeTrackColor: cs.primary,
        ),
      ],
    );
  }

  Widget _chip(
    String label,
    bool selected,
    VoidCallback onTap,
    ColorScheme cs,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? cs.primary
                : cs.onSurfaceVariant.withValues(alpha: 0.2),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? cs.primary : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Humanized condition presets for step execution.
class _ConditionPreset {
  const _ConditionPreset({required this.label, required this.value});

  final String label;
  final String? value;

  static List<_ConditionPreset> all(AppStrings s) {
    return [
      _ConditionPreset(
        label: s.workflowAlwaysRun,
        value: null,
      ),
      _ConditionPreset(
        label: s.wfConditionOnlyIfPrevSuccess,
        value: 'prev.isNotEmpty',
      ),
      _ConditionPreset(
        label: s.wfConditionOnlyIfPrevEmpty,
        value: 'prev.isEmpty',
      ),
      _ConditionPreset(
        label: s.wfConditionIfPrevShort,
        value: 'prev.length < 50',
      ),
      _ConditionPreset(
        label: s.wfConditionIfPrevLong,
        value: 'prev.length > 200',
      ),
      _ConditionPreset(
        label: s.wfConditionIfContainsSukses,
        value: "prev.contains('sukses')",
      ),
      _ConditionPreset(
        label: s.wfConditionIfContainsError,
        value: "prev.contains('error')",
      ),
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is _ConditionPreset && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

class _VariableTrigger {
  const _VariableTrigger(this.start, this.end, this.query);

  final int start;
  final int end;
  final String query;
}

class _VariableTextEditingController extends TextEditingController {
  _VariableTextEditingController({super.text});

  // Match @key tokens AND @api:name tokens with a left-side word boundary.
  static final _pattern = RegExp(r'(?<![\w@])@(\w+(?::\w+)?)');

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final textValue = text;
    final spans = <TextSpan>[];
    var cursor = 0;

    for (final match in _pattern.allMatches(textValue)) {
      final key = match.group(1) ?? '';
      // Only color KNOWN built-ins (static catalog OR dynamic @stepN). Unknown
      // @foo stays plain so the user can tell it's not a real placeholder.
      if (!isKnownBuiltInKey(key)) continue;

      if (match.start > cursor) {
        spans.add(TextSpan(text: textValue.substring(cursor, match.start)));
      }
      spans.add(
        TextSpan(
          text: textValue.substring(match.start, match.end),
          style: base.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w800,
            fontFamily: 'monospace',
          ),
        ),
      );
      cursor = match.end;
    }

    if (cursor < textValue.length) {
      spans.add(TextSpan(text: textValue.substring(cursor)));
    }

    return TextSpan(style: base, children: spans);
  }
}

/// Treats a complete `@key` placeholder like an atomic chip for deletion when
/// `key` matches a registered built-in. The whole token is removed only when:
/// - backspace is pressed right after it
/// - cursor/selection is inside it
class _VariableTokenDeleteFormatter extends TextInputFormatter {
  const _VariableTokenDeleteFormatter();

  static final _pattern = RegExp(r'(?<![\w@])@(\w+)');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final oldText = oldValue.text;
    final newText = newValue.text;
    if (newText.length >= oldText.length) return newValue;

    final oldSel = oldValue.selection;
    if (!oldSel.isValid) return newValue;

    for (final match in _pattern.allMatches(oldText)) {
      final key = match.group(1) ?? '';
      // Only atomize valid built-in tokens (static OR dynamic @stepN) — unknown
      // @foo behaves like prose.
      if (!isKnownBuiltInKey(key)) continue;

      final selectionInsideToken =
          !oldSel.isCollapsed &&
          oldSel.end > match.start &&
          oldSel.start < match.end;
      final cursorInsideToken =
          oldSel.isCollapsed &&
          oldSel.baseOffset > match.start &&
          oldSel.baseOffset < match.end;
      final backspaceAtRightEdge =
          oldSel.isCollapsed && oldSel.baseOffset == match.end;
      if (!selectionInsideToken &&
          !cursorInsideToken &&
          !backspaceAtRightEdge) {
        continue;
      }

      final next = oldText.replaceRange(match.start, match.end, '');
      return TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: match.start),
      );
    }
    return newValue;
  }
}
