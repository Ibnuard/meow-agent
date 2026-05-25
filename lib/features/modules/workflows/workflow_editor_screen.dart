import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme.dart';
import '../../agents/data/agent_model.dart';
import '../../agents/data/agent_repository.dart';
import '../../settings/data/app_language_provider.dart';
import 'workflow_model.dart';
import 'workflow_repository.dart';
import 'workflow_scheduler.dart';

/// Create or edit a workflow.
class WorkflowEditorScreen extends ConsumerStatefulWidget {
  const WorkflowEditorScreen({super.key, this.workflow});
  final WorkflowModel? workflow;

  @override
  ConsumerState<WorkflowEditorScreen> createState() => _WorkflowEditorScreenState();
}

class _WorkflowEditorScreenState extends ConsumerState<WorkflowEditorScreen> {
  final _repo = WorkflowRepository();
  final _titleCtrl = TextEditingController();
  final _promptCtrl = TextEditingController();

  bool get _isEdit => widget.workflow != null;

  String? _selectedAgentId;
  TriggerType _triggerType = TriggerType.schedule;
  TimeOfDay _time = const TimeOfDay(hour: 8, minute: 0);
  List<int> _selectedDays = [1, 2, 3, 4, 5, 6, 7]; // All days
  int _intervalMinutes = 60;
  NotifStyle _notifStyle = NotifStyle.normal;
  bool _sendToChat = false;

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      final wf = widget.workflow!;
      _titleCtrl.text = wf.title;
      _promptCtrl.text = wf.prompt;
      _selectedAgentId = wf.agentId;
      _triggerType = wf.trigger.type;
      _time = TimeOfDay(hour: wf.trigger.hour ?? 8, minute: wf.trigger.minute ?? 0);
      _selectedDays = wf.trigger.daysOfWeek ?? [1, 2, 3, 4, 5, 6, 7];
      _intervalMinutes = wf.trigger.intervalMinutes ?? 60;
      _notifStyle = wf.notification.style;
      _sendToChat = wf.sendToChat;
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty || _promptCtrl.text.trim().isEmpty) return;
    if (_selectedAgentId == null) return;

    final trigger = TriggerConfig(
      type: _triggerType,
      hour: _triggerType == TriggerType.schedule ? _time.hour : null,
      minute: _triggerType == TriggerType.schedule ? _time.minute : null,
      daysOfWeek: _triggerType == TriggerType.schedule ? _selectedDays : null,
      intervalMinutes: _triggerType == TriggerType.interval ? _intervalMinutes : null,
    );

    final notif = NotifConfig(style: _notifStyle, showResult: true);

    if (_isEdit) {
      final updated = widget.workflow!.copyWith(
        agentId: _selectedAgentId,
        title: _titleCtrl.text.trim(),
        prompt: _promptCtrl.text.trim(),
        trigger: trigger,
        notification: notif,
        sendToChat: _sendToChat,
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
        enabled: true,
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
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
    );
    if (picked != null) setState(() => _time = picked);
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final langPref = ref.watch(appLanguageProvider);
    final isId = resolveLanguageCode(langPref) == 'id';
    final agents = ref.watch(agentListProvider);

    // Default to first agent if none selected.
    if (_selectedAgentId == null && agents.isNotEmpty) {
      _selectedAgentId = agents.first.id;
    }

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isEdit
              ? (isId ? 'Edit Workflow' : 'Edit Workflow')
              : (isId ? 'Buat Workflow' : 'New Workflow')),
        ),
        body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Agent picker.
            _sectionLabel(isId ? 'Agent' : 'Agent', cs),
            const SizedBox(height: 8),
            _buildAgentPicker(agents, cs, extras),
            const SizedBox(height: 20),

            // Title.
            _sectionLabel(isId ? 'Judul' : 'Title', cs),
            const SizedBox(height: 8),
            _buildInput(_titleCtrl, isId ? 'Nama workflow' : 'Workflow name', cs, extras),
            const SizedBox(height: 20),

            // Prompt.
            _sectionLabel('Prompt', cs),
            const SizedBox(height: 8),
            _buildInput(
              _promptCtrl,
              isId ? 'Apa yang harus agent lakukan...' : 'What should the agent do...',
              cs,
              extras,
              maxLines: 4,
            ),
            const SizedBox(height: 24),

            // Trigger type.
            _sectionLabel(isId ? 'Trigger' : 'Trigger', cs),
            const SizedBox(height: 8),
            _buildTriggerSelector(cs, extras, isId),
            const SizedBox(height: 16),

            if (_triggerType == TriggerType.schedule) ...[
              _buildTimePicker(cs, extras, isId),
              const SizedBox(height: 12),
              _buildDaySelector(cs, isId),
            ] else ...[
              _buildIntervalPicker(cs, extras, isId),
            ],
            const SizedBox(height: 24),

            // Notification style.
            _sectionLabel(isId ? 'Notifikasi' : 'Notification', cs),
            const SizedBox(height: 8),
            _buildNotifSelector(cs, extras, isId),
            const SizedBox(height: 20),

            // Send to chat toggle.
            _buildToggle(
              isId ? 'Kirim hasil ke chat' : 'Send result to chat',
              _sendToChat,
              (v) => setState(() => _sendToChat = v),
              cs,
            ),
            const SizedBox(height: 32),

            // Save button.
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
                  _isEdit ? (isId ? 'Simpan' : 'Save') : (isId ? 'Buat Workflow' : 'Create'),
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

  Widget _sectionLabel(String text, ColorScheme cs) => Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: cs.onSurfaceVariant,
        ),
      );

  Widget _buildInput(
    TextEditingController ctrl,
    String hint,
    ColorScheme cs,
    MeowExtras extras, {
    int maxLines = 1,
  }) {
    return TextField(
      controller: ctrl,
      maxLines: maxLines,
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  Widget _buildAgentPicker(List<AgentModel> agents, ColorScheme cs, MeowExtras extras) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: extras.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: extras.subtleBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedAgentId,
          isExpanded: true,
          dropdownColor: extras.card,
          style: TextStyle(fontSize: 14, color: cs.onSurface),
          items: agents
              .map((a) => DropdownMenuItem(value: a.id, child: Text(a.name)))
              .toList(),
          onChanged: (v) => setState(() => _selectedAgentId = v),
        ),
      ),
    );
  }

  Widget _buildTriggerSelector(ColorScheme cs, MeowExtras extras, bool isId) {
    return Row(
      children: [
        _chip(
          isId ? 'Jadwal' : 'Schedule',
          _triggerType == TriggerType.schedule,
          () => setState(() => _triggerType = TriggerType.schedule),
          cs,
        ),
        const SizedBox(width: 8),
        _chip(
          'Interval',
          _triggerType == TriggerType.interval,
          () => setState(() => _triggerType = TriggerType.interval),
          cs,
        ),
      ],
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
          onTap: () {
            setState(() {
              if (selected) {
                _selectedDays.remove(day);
              } else {
                _selectedDays.add(day);
              }
            });
          },
          child: Container(
            width: 40,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? cs.primary.withValues(alpha: 0.15) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.2),
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

  Widget _buildIntervalPicker(ColorScheme cs, MeowExtras extras, bool isId) {
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
              color: selected ? cs.primary.withValues(alpha: 0.15) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.2),
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

  Widget _buildNotifSelector(ColorScheme cs, MeowExtras extras, bool isId) {
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

  Widget _buildToggle(String label, bool value, ValueChanged<bool> onChanged, ColorScheme cs) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: cs.onSurface)),
        Switch(value: value, onChanged: onChanged, activeTrackColor: cs.primary),
      ],
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap, ColorScheme cs) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? cs.primary.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.2),
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
