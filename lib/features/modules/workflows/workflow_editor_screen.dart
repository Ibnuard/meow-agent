import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../agents/data/agent_model.dart';
import '../../agents/data/agent_repository.dart';
import '../../settings/data/app_language_provider.dart';
import 'workflow_model.dart';
import 'workflow_repository.dart';
import 'workflow_scheduler.dart';
import 'workflow_templates.dart';

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
  final _promptCtrl = TextEditingController();
  final _keywordCtrl = TextEditingController();

  bool get _isEdit => widget.workflow != null;

  String? _selectedAgentId;
  TriggerType _triggerType = TriggerType.schedule;
  EventTriggerKind _eventKind = EventTriggerKind.batteryLow;
  int _batteryThreshold = 20;
  TimeOfDay _time = const TimeOfDay(hour: 8, minute: 0);
  List<int> _selectedDays = [1, 2, 3, 4, 5, 6, 7];
  int _intervalMinutes = 60;
  NotifStyle _notifStyle = NotifStyle.normal;
  bool _sendToChat = false;
  bool _allowSensitive = false;
  WorkflowPriority _priority = WorkflowPriority.normal;
  int _timeoutSeconds = 300;
  List<WorkflowStep> _steps = [];
  Map<String, String> _variables = {};
  String? _templateId;

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
    _promptCtrl.text = wf.prompt;
    _selectedAgentId = wf.agentId;
    _triggerType = wf.trigger.type;
    _eventKind = wf.trigger.eventKind ?? EventTriggerKind.batteryLow;
    _batteryThreshold = (wf.trigger.eventParams?['threshold'] as int?) ?? 20;
    _keywordCtrl.text = (wf.trigger.eventParams?['keyword'] as String?) ?? '';
    _time = TimeOfDay(
      hour: wf.trigger.hour ?? 8,
      minute: wf.trigger.minute ?? 0,
    );
    _selectedDays = List<int>.from(wf.trigger.daysOfWeek ?? [1, 2, 3, 4, 5, 6, 7]);
    _intervalMinutes = wf.trigger.intervalMinutes ?? 60;
    _notifStyle = wf.notification.style;
    _sendToChat = wf.sendToChat;
    _allowSensitive = wf.allowSensitive;
    _priority = wf.priority;
    _timeoutSeconds = _snapTimeoutToOption(wf.timeoutSeconds);
    _steps = List.from(wf.steps);
    _variables = Map.from(wf.variables);
    _templateId = wf.templateId;
  }

  void _loadFromTemplate(WorkflowTemplate tpl) {
    _titleCtrl.text = tpl.titleId;
    _promptCtrl.text = tpl.defaultPrompt;
    _templateId = tpl.id;
    if (tpl.defaultTrigger != null) {
      final t = tpl.defaultTrigger!;
      _triggerType = t.type;
      _eventKind = t.eventKind ?? EventTriggerKind.batteryLow;
      _batteryThreshold = (t.eventParams?['threshold'] as int?) ?? 20;
      _keywordCtrl.text = (t.eventParams?['keyword'] as String?) ?? '';
      if (t.hour != null) {
        _time = TimeOfDay(hour: t.hour!, minute: t.minute ?? 0);
      }
      _selectedDays = List<int>.from(t.daysOfWeek ?? [1, 2, 3, 4, 5, 6, 7]);
      _intervalMinutes = t.intervalMinutes ?? 60;
    }
    _steps = List.from(tpl.defaultSteps);
    _variables = Map.from(tpl.defaultVariables);
    _priority = tpl.defaultPriority;
    _timeoutSeconds = _snapTimeoutToOption(tpl.defaultTimeoutSeconds);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _promptCtrl.dispose();
    _keywordCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final isId = Localizations.localeOf(context).languageCode == 'id';
    if (_selectedAgentId == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isId ? 'Pilih agent terlebih dahulu.' : 'Please select an agent.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    if (_titleCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isId ? 'Judul workflow tidak boleh kosong.' : 'Workflow title is required.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    if (_steps.isEmpty && _promptCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isId ? 'Prompt atau langkah tidak boleh kosong.' : 'Prompt or steps are required.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    Map<String, dynamic>? eventParams;
    if (_triggerType == TriggerType.event) {
      switch (_eventKind) {
        case EventTriggerKind.batteryLow:
          eventParams = {'threshold': _batteryThreshold};
          break;
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
        .map((s) => WorkflowStep(
              id: s.id,
              prompt: s.prompt,
              condition: s.condition,
              onFailure: s.onFailure,
              timeoutSeconds: _timeoutSeconds,
            ))
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
        variables: _variables,
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
        variables: _variables,
        templateId: _templateId,
        createdAt: DateTime.now(),
      );
      final success = await _repo.create(workflow);
      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Max 20 workflows reached.')),
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

  Future<void> _confirmDelete(bool isId) async {
    if (widget.workflow == null) return;
    final wf = widget.workflow!;
    final confirm = await showMeowConfirmDialog(
      context,
      isId: isId,
      title: isId ? 'Hapus Workflow?' : 'Delete Workflow?',
      message: isId
          ? 'Workflow "${wf.title}" akan dihapus permanen. Lanjutkan?'
          : 'Workflow "${wf.title}" will be permanently deleted. Continue?',
      confirmLabel: isId ? 'Hapus' : 'Delete',
      cancelLabel: isId ? 'Batal' : 'Cancel',
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

  void _removeStep(int index) {
    setState(() => _steps.removeAt(index));
  }

  void _updateStep(int index, WorkflowStep updated) {
    setState(() => _steps[index] = updated);
  }

  void _addVariable() async {
    final result = await showDialog<MapEntry<String, String>>(
      context: context,
      builder: (ctx) => _VariableDialog(),
    );
    if (result != null) {
      setState(() => _variables[result.key] = result.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final langPref = ref.watch(appLanguageProvider);
    final isId = resolveLanguageCode(langPref) == 'id';
    final agents = ref.watch(agentListProvider);

    if (_selectedAgentId == null && agents.isNotEmpty) {
      _selectedAgentId = agents.first.id;
    }

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _isEdit
                ? (isId ? 'Edit Workflow' : 'Edit Workflow')
                : (isId ? 'Buat Workflow' : 'New Workflow'),
          ),
          actions: [
            if (_isEdit)
              IconButton(
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                ),
                tooltip: isId ? 'Hapus' : 'Delete',
                onPressed: () => _confirmDelete(isId),
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
              _sectionLabel(isId ? 'Agent' : 'Agent', cs),
              const SizedBox(height: 8),
              _buildAgentPicker(agents, isId),
              const SizedBox(height: 20),

              _sectionLabel(isId ? 'Judul' : 'Title', cs),
              const SizedBox(height: 8),
              _buildInput(
                _titleCtrl,
                isId ? 'Nama workflow' : 'Workflow name',
                cs,
                extras,
              ),
              const SizedBox(height: 20),

              // Mode toggle: single prompt vs chained steps.
              Row(
                children: [
                  _sectionLabel(isId ? 'Mode' : 'Mode', cs),
                  const Spacer(),
                  Text(
                    _steps.isEmpty
                        ? (isId ? 'Single Prompt' : 'Single Prompt')
                        : '${_steps.length} ${isId ? "langkah" : "steps"}',
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
                _buildInput(
                  _promptCtrl,
                  isId
                      ? 'Apa yang harus agent lakukan...'
                      : 'What should the agent do...',
                  cs,
                  extras,
                  maxLines: 4,
                  onChanged: (_) => setState(() {}),
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
                ..._buildStepList(cs, extras, isId),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _addStep,
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: Text(isId ? 'Tambah Langkah' : 'Add Step'),
                ),
              ],
              const SizedBox(height: 24),

              // ─── Variables (moved above Trigger) ───────────────────
              _buildVariablesSection(cs, extras, isId),
              const SizedBox(height: 24),

              _sectionLabel(isId ? 'Trigger' : 'Trigger', cs),
              const SizedBox(height: 8),
              _buildTriggerSelector(cs, isId),
              const SizedBox(height: 16),

              if (_triggerType == TriggerType.schedule) ...[
                _buildTimePicker(cs, extras, isId),
                const SizedBox(height: 12),
                _buildDaySelector(cs, isId),
              ] else if (_triggerType == TriggerType.interval) ...[
                _buildIntervalPicker(cs, isId),
              ] else ...[
                _buildEventTriggerConfig(cs, extras, isId),
              ],
              const SizedBox(height: 24),

              _sectionLabel(isId ? 'Notifikasi' : 'Notification', cs),
              const SizedBox(height: 8),
              _buildNotifSelector(cs, isId),
              const SizedBox(height: 20),

              // ─── Priority (moved below Notifikasi) ─────────────────
              _sectionLabel(isId ? 'Prioritas' : 'Priority', cs),
              const SizedBox(height: 8),
              _buildPrioritySelector(cs, isId),
              const SizedBox(height: 20),

              _sectionLabel(isId ? 'Timeout' : 'Timeout', cs),
              const SizedBox(height: 8),
              _buildTimeoutSelector(cs, isId),
              const SizedBox(height: 20),

              _buildToggle(
                isId ? 'Kirim hasil ke chat' : 'Send result to chat',
                _sendToChat,
                (v) => setState(() => _sendToChat = v),
                cs,
              ),
              const SizedBox(height: 14),
              _buildToggleWithDesc(
                isId ? 'Izinkan Aksi Sensitif' : 'Allow Sensitive Actions',
                isId
                    ? 'Setujui otomatis aksi yang biasanya butuh konfirmasi.'
                    : 'Auto-approve actions that normally require confirmation.',
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
                    _isEdit
                        ? (isId ? 'Simpan' : 'Save')
                        : (isId ? 'Buat Workflow' : 'Create'),
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

  // ─── Step List Builders ─────────────────────────────────────────────────────

  List<Widget> _buildStepList(ColorScheme cs, MeowExtras extras, bool isId) {
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
                    isId ? 'Langkah ${i + 1}' : 'Step ${i + 1}',
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
            TextFormField(
              key: ValueKey('step_prompt_${step.id}'),
              initialValue: step.prompt,
              maxLines: 3,
              style: TextStyle(fontSize: 13, color: cs.onSurface),
              decoration: InputDecoration(
                hintText: isId
                    ? 'Apa yang harus dilakukan di langkah ini?'
                    : 'What should happen in this step?',
                hintStyle: TextStyle(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onChanged: (v) {
                _updateStep(
                  i,
                  WorkflowStep(
                    id: step.id,
                    prompt: v,
                    condition: step.condition,
                    onFailure: step.onFailure,
                    timeoutSeconds: step.timeoutSeconds,
                  ),
                );
                setState(() {}); // refresh variable suggestions
              },
            ),
            const SizedBox(height: 10),
            // Condition preset dropdown.
            if (i > 0) ...[
              Text(
                isId
                    ? 'Kapan langkah ini berjalan?'
                    : 'When does this step run?',
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              _buildConditionDropdown(step, i, cs, extras, isId),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                Text(
                  isId ? 'Jika gagal:' : 'On failure:',
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
                          _failureActionLabel(a, isId),
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

  String _failureActionLabel(StepFailureAction a, bool isId) {
    switch (a) {
      case StepFailureAction.stop:
        return isId ? 'Hentikan' : 'Stop';
      case StepFailureAction.skip:
        return isId ? 'Lewati' : 'Skip';
      case StepFailureAction.retry:
        return isId ? 'Coba lagi' : 'Retry';
    }
  }

  Widget _buildConditionDropdown(
    WorkflowStep step,
    int index,
    ColorScheme cs,
    MeowExtras extras,
    bool isId,
  ) {
    final presets = _ConditionPreset.all(isId);
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
            condition: value.value,
            onFailure: step.onFailure,
            timeoutSeconds: step.timeoutSeconds,
          ),
        );
      },
    );
  }

  // ─── Variables Section ──────────────────────────────────────────────────────

  /// Detect {{varName}} patterns from prompt and steps.
  Set<String> _detectUsedVariables() {
    final pattern = RegExp(r'\{\{(\w+)\}\}');
    final used = <String>{};
    final allText = StringBuffer(_promptCtrl.text);
    for (final s in _steps) {
      allText.write(' ');
      allText.write(s.prompt);
    }
    for (final match in pattern.allMatches(allText.toString())) {
      final name = match.group(1);
      if (name != null && name.isNotEmpty) used.add(name);
    }
    // Exclude reserved runtime vars.
    used.removeAll(['prev', 'step_index', 'date']);
    return used;
  }

  Widget _buildVariablesSection(ColorScheme cs, MeowExtras extras, bool isId) {
    final usedVars = _detectUsedVariables();
    final undefinedVars = usedVars
        .where((v) => !_variables.containsKey(v))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _sectionLabel(isId ? 'Variabel' : 'Variables', cs),
            const Spacer(),
            TextButton.icon(
              onPressed: _addVariable,
              icon: const Icon(Icons.add_rounded, size: 14),
              label: Text(
                isId ? 'Tambah' : 'Add',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          isId
              ? 'Tulis {{nama}} di prompt untuk menggunakan variabel.'
              : 'Write {{name}} in prompts to use variables.',
          style: TextStyle(
            fontSize: 11,
            color: cs.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
        // System variables info — only shown for multi-step workflows.
        if (_steps.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: cs.onSurfaceVariant.withValues(alpha: 0.1)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline_rounded, size: 13, color: cs.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(
                      isId ? 'Variabel Sistem (otomatis):' : 'System Variables (auto):',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _systemVarRow('{{prev}}',
                    isId ? 'Hasil output dari langkah sebelumnya' : 'Output from the previous step',
                    cs),
                const SizedBox(height: 3),
                _systemVarRow('{{date}}',
                    isId ? 'Tanggal hari ini (YYYY-MM-DD)' : 'Today\'s date (YYYY-MM-DD)',
                    cs),
                const SizedBox(height: 3),
                _systemVarRow('{{step_index}}',
                    isId ? 'Nomor urut langkah saat ini (0, 1, 2...)' : 'Current step index (0, 1, 2...)',
                    cs),
              ],
            ),
          ),
        ],
        if (undefinedVars.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: 14,
                      color: cs.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isId ? 'Saran dari prompt:' : 'Detected in prompts:',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: undefinedVars
                      .map(
                        (name) => GestureDetector(
                          onTap: () => _addSuggestedVariable(name),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: cs.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: cs.primary.withValues(alpha: 0.4),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.add_rounded,
                                  size: 12,
                                  color: cs.primary,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  name,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.primary,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
        ],
        if (_variables.isNotEmpty) ...[
          const SizedBox(height: 10),
          ..._variables.entries.map(
            (e) => Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: extras.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: extras.subtleBorder),
              ),
              child: Row(
                children: [
                  Text(
                    '{{${e.key}}}',
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.primary,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '= ${e.value.isEmpty ? (isId ? "(kosong)" : "(empty)") : e.value}',
                      style: TextStyle(fontSize: 12, color: cs.onSurface),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.edit_outlined,
                      size: 16,
                      color: cs.onSurfaceVariant,
                    ),
                    onPressed: () => _editVariable(e.key, e.value),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: cs.onSurfaceVariant,
                    ),
                    onPressed: () => setState(() => _variables.remove(e.key)),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _addSuggestedVariable(String name) async {
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => _VariableValueDialog(name: name),
    );
    if (value != null) {
      setState(() => _variables[name] = value);
    }
  }

  Future<void> _editVariable(String name, String currentValue) async {
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) =>
          _VariableValueDialog(name: name, initialValue: currentValue),
    );
    if (value != null) {
      setState(() => _variables[name] = value);
    }
  }

  // ─── Trigger Builders ───────────────────────────────────────────────────────

  Widget _buildTriggerSelector(ColorScheme cs, bool isId) {
    return Wrap(
      spacing: 8,
      children: [
        _chip(
          isId ? 'Jadwal' : 'Schedule',
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
          isId ? 'Event' : 'Event',
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
    bool isId,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(isId ? 'Jenis Event' : 'Event Type', cs),
        const SizedBox(height: 8),
        MeowDropdown<EventTriggerKind>(
          value: _eventKind,
          presentation: MeowDropdownPresentation.menu,
          searchable: false,
          dense: true,
          options: EventTriggerKind.values
              .map(
                (kind) => MeowDropdownOption<EventTriggerKind>(
                  value: kind,
                  label: _eventKindLabel(kind, isId),
                ),
              )
              .toList(),
          onChanged: (value) =>
              setState(() => _eventKind = value ?? EventTriggerKind.batteryLow),
        ),
        const SizedBox(height: 12),
        if (_eventKind == EventTriggerKind.batteryLow) ...[
          _sectionLabel(isId ? 'Threshold (%)' : 'Threshold (%)', cs),
          const SizedBox(height: 8),
          Slider(
            value: _batteryThreshold.toDouble(),
            min: 5,
            max: 50,
            divisions: 9,
            label: '$_batteryThreshold%',
            onChanged: (v) => setState(() => _batteryThreshold = v.toInt()),
          ),
        ] else if (_eventKind == EventTriggerKind.notificationKeyword) ...[
          _sectionLabel(isId ? 'Kata Kunci' : 'Keyword', cs),
          const SizedBox(height: 8),
          _buildInput(
            _keywordCtrl,
            isId ? 'mis: urgent, meeting' : 'e.g. urgent, meeting',
            cs,
            extras,
          ),
        ],
      ],
    );
  }

  String _eventKindLabel(EventTriggerKind k, bool isId) {
    switch (k) {
      case EventTriggerKind.batteryLow:
        return isId ? '🔋 Baterai Rendah' : '🔋 Battery Low';
      case EventTriggerKind.batteryFull:
        return isId ? '🔋 Baterai Penuh' : '🔋 Battery Full';
      case EventTriggerKind.chargingStart:
        return isId ? '🔌 Mulai Charging' : '🔌 Charging Start';
      case EventTriggerKind.chargingStop:
        return isId ? '🔌 Berhenti Charging' : '🔌 Charging Stop';
      case EventTriggerKind.notificationKeyword:
        return isId ? '🔔 Notifikasi (Keyword)' : '🔔 Notification (Keyword)';
      case EventTriggerKind.appOpened:
        return isId ? '📱 Aplikasi Dibuka' : '📱 App Opened';
      case EventTriggerKind.wifiConnected:
        return isId ? '📶 WiFi Terhubung' : '📶 WiFi Connected';
      case EventTriggerKind.wifiDisconnected:
        return isId ? '📶 WiFi Terputus' : '📶 WiFi Disconnected';
    }
  }

  Widget _buildPrioritySelector(ColorScheme cs, bool isId) {
    return Wrap(
      spacing: 8,
      children: WorkflowPriority.values.map((p) {
        return _chip(
          _priorityLabel(p, isId),
          _priority == p,
          () => setState(() => _priority = p),
          cs,
        );
      }).toList(),
    );
  }

  String _priorityLabel(WorkflowPriority p, bool isId) {
    switch (p) {
      case WorkflowPriority.low:
        return isId ? 'Rendah' : 'Low';
      case WorkflowPriority.normal:
        return 'Normal';
      case WorkflowPriority.high:
        return isId ? 'Tinggi' : 'High';
      case WorkflowPriority.critical:
        return isId ? 'Kritis' : 'Critical';
    }
  }

  Widget _buildTimeoutSelector(ColorScheme cs, bool isId) {
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

  Widget _systemVarRow(String varName, String desc, ColorScheme cs) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          varName,
          style: TextStyle(
            fontSize: 11,
            color: cs.primary.withValues(alpha: 0.8),
            fontFamily: 'monospace',
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            desc,
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
    );
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

  Widget _buildAgentPicker(List<AgentModel> agents, bool isId) {
    final selectedValue = agents.any((a) => a.id == _selectedAgentId)
        ? _selectedAgentId
        : null;

    return MeowDropdown<String>(
      value: selectedValue,
      enabled: agents.isNotEmpty,
      hint: agents.isEmpty
          ? (isId ? 'Belum ada agen' : 'No agents yet')
          : (isId ? 'Pilih agen' : 'Choose agent'),
      sheetTitle: isId ? 'Pilih Agen' : 'Choose Agent',
      searchHint: isId ? 'Cari agen' : 'Search agents',
      emptyText: isId ? 'Agen tidak ditemukan' : 'No agents found',
      options: agents
          .map(
            (agent) => MeowDropdownOption<String>(
              value: agent.id,
              label: agent.name.trim().isEmpty
                  ? (isId ? 'Agen tanpa nama' : 'Untitled agent')
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

  Widget _buildTimePicker(ColorScheme cs, MeowExtras extras, bool isId) {
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
              isId ? 'Ubah' : 'Change',
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
    final options = [15, 30, 60, 120, 360, 720, 1440];
    final labels = ['15m', '30m', '1h', '2h', '6h', '12h', '24h'];
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

  Widget _buildNotifSelector(ColorScheme cs, bool isId) {
    return Row(
      children: [
        _chip(
          isId ? 'Senyap' : 'Silent',
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

/// Dialog for adding a new variable.
class _VariableDialog extends StatefulWidget {
  @override
  State<_VariableDialog> createState() => _VariableDialogState();
}

class _VariableDialogState extends State<_VariableDialog> {
  final _nameCtrl = TextEditingController();
  final _valueCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Tambah Variabel'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Nama',
              hintText: 'mis: city',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _valueCtrl,
            decoration: const InputDecoration(
              labelText: 'Nilai Default',
              hintText: 'mis: Jakarta',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        TextButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isNotEmpty) {
              Navigator.pop(context, MapEntry(name, _valueCtrl.text.trim()));
            }
          },
          child: const Text('Tambah'),
        ),
      ],
    );
  }
}

/// Humanized condition presets for step execution.
class _ConditionPreset {
  const _ConditionPreset({required this.label, required this.value});

  final String label;
  final String? value;

  static List<_ConditionPreset> all(bool isId) {
    return [
      _ConditionPreset(
        label: isId ? 'Selalu jalan' : 'Always run',
        value: null,
      ),
      _ConditionPreset(
        label: isId
            ? 'Hanya jika langkah sebelumnya berhasil'
            : 'Only if previous step succeeded',
        value: 'prev.isNotEmpty',
      ),
      _ConditionPreset(
        label: isId
            ? 'Hanya jika langkah sebelumnya kosong'
            : 'Only if previous step is empty',
        value: 'prev.isEmpty',
      ),
      _ConditionPreset(
        label: isId
            ? 'Jika hasil sebelumnya pendek (< 50 karakter)'
            : 'If previous result is short (< 50 chars)',
        value: 'prev.length < 50',
      ),
      _ConditionPreset(
        label: isId
            ? 'Jika hasil sebelumnya panjang (> 200 karakter)'
            : 'If previous result is long (> 200 chars)',
        value: 'prev.length > 200',
      ),
      _ConditionPreset(
        label: isId
            ? "Jika hasil mengandung 'sukses'"
            : "If result contains 'success'",
        value: "prev.contains('sukses')",
      ),
      _ConditionPreset(
        label: isId
            ? "Jika hasil mengandung 'error'"
            : "If result contains 'error'",
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

/// Dialog for setting a variable value (used by suggestions and edit).
class _VariableValueDialog extends StatefulWidget {
  const _VariableValueDialog({required this.name, this.initialValue = ''});

  final String name;
  final String initialValue;

  @override
  State<_VariableValueDialog> createState() => _VariableValueDialogState();
}

class _VariableValueDialogState extends State<_VariableValueDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text('{{${widget.name}}}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Nilai default untuk variabel ini',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'mis: Jakarta, urgent, dst',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.pop(context, v.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
