import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../settings/data/app_language_provider.dart';
import 'calendar_event_model.dart';
import 'calendar_screen.dart';

/// Event editor screen — create or edit a calendar event.
class CalendarEventEditor extends ConsumerStatefulWidget {
  const CalendarEventEditor({
    super.key,
    this.event,
    this.initialDate,
  });

  final CalendarEvent? event;
  final DateTime? initialDate;

  @override
  ConsumerState<CalendarEventEditor> createState() =>
      _CalendarEventEditorState();
}

class _CalendarEventEditorState extends ConsumerState<CalendarEventEditor> {
  final _titleController = TextEditingController();
  final _descController = TextEditingController();
  late DateTime _startDate;
  late TimeOfDay _startTime;
  late DateTime _endDate;
  late TimeOfDay _endTime;
  bool _allDay = false;
  bool _saving = false;

  bool get _isEditing => widget.event != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      final e = widget.event!;
      _titleController.text = e.title;
      _descController.text = e.description;
      _startDate = e.startTime;
      _startTime = TimeOfDay.fromDateTime(e.startTime);
      _endDate = e.endTime;
      _endTime = TimeOfDay.fromDateTime(e.endTime);
      _allDay = e.allDay;
    } else {
      final initial = widget.initialDate ?? DateTime.now();
      _startDate = initial;
      _startTime = TimeOfDay.fromDateTime(
        DateTime.now().add(const Duration(hours: 1)),
      );
      _endDate = initial;
      _endTime = TimeOfDay.fromDateTime(
        DateTime.now().add(const Duration(hours: 2)),
      );
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _pickDate(bool isStart) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _startDate : _endDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startDate = picked;
          if (_endDate.isBefore(_startDate)) _endDate = _startDate;
        } else {
          _endDate = picked;
        }
      });
    }
  }

  Future<void> _pickTime(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _startTime : _endTime,
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startTime = picked;
        } else {
          _endTime = picked;
        }
      });
    }
  }

  DateTime _combineDateAndTime(DateTime date, TimeOfDay time) {
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      final s = AppStrings(resolveLanguageCode(ref.read(appLanguageProvider)));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.calendarEventTitleRequired)),
      );
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(calendarRepositoryProvider);

    final start = _allDay
        ? DateTime(_startDate.year, _startDate.month, _startDate.day)
        : _combineDateAndTime(_startDate, _startTime);
    final end = _allDay
        ? DateTime(_endDate.year, _endDate.month, _endDate.day, 23, 59)
        : _combineDateAndTime(_endDate, _endTime);

    try {
      if (_isEditing) {
        await repo.updateEvent(
          widget.event!.id,
          title: title,
          description: _descController.text.trim(),
          startTime: start,
          endTime: end,
          allDay: _allDay,
        );
      } else {
        await repo.createEvent(
          title: title,
          description: _descController.text.trim(),
          startTime: start,
          endTime: end,
          allDay: _allDay,
          source: 'user',
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _delete() async {
    if (!_isEditing) return;
    final confirm = await showMeowConfirmDialog(
      context,
      title: 'Hapus Event?',
      message: 'Event ini akan dihapus permanen. Lanjutkan?',
    );
    if (!confirm) return;

    final repo = ref.read(calendarRepositoryProvider);
    await repo.deleteEvent(widget.event!.id);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Event' : 'Buat Event'),
        actions: [
          if (_isEditing)
            IconButton(
              icon: Icon(Icons.delete_outline_rounded, color: cs.error),
              onPressed: _delete,
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title.
              _buildInput(
                controller: _titleController,
                hint: 'Judul event',
                cs: cs,
                extras: extras,
              ),
              const SizedBox(height: 16),

              // Description.
              _buildInput(
                controller: _descController,
                hint: 'Deskripsi (opsional)',
                cs: cs,
                extras: extras,
                maxLines: 3,
              ),
              const SizedBox(height: 20),

              // All day toggle.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  color: extras.card,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: extras.subtleBorder),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Seharian',
                      style: TextStyle(fontSize: 14, color: cs.onSurface),
                    ),
                    Switch(
                      value: _allDay,
                      onChanged: (v) => setState(() => _allDay = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Start date/time.
              _buildDateTimeRow(
                label: 'Mulai',
                date: _startDate,
                time: _startTime,
                onDateTap: () => _pickDate(true),
                onTimeTap: _allDay ? null : () => _pickTime(true),
                cs: cs,
                extras: extras,
              ),
              const SizedBox(height: 12),

              // End date/time.
              _buildDateTimeRow(
                label: 'Selesai',
                date: _endDate,
                time: _endTime,
                onDateTap: () => _pickDate(false),
                onTimeTap: _allDay ? null : () => _pickTime(false),
                cs: cs,
                extras: extras,
              ),
              const SizedBox(height: 28),

              // Save button.
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cs.primary,
                    foregroundColor: cs.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          _isEditing ? 'Simpan' : 'Buat Event',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInput({
    required TextEditingController controller,
    required String hint,
    required ColorScheme cs,
    required MeowExtras extras,
    int maxLines = 1,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: extras.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: extras.subtleBorder),
      ),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        style: TextStyle(fontSize: 14, color: cs.onSurface),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
    );
  }

  Widget _buildDateTimeRow({
    required String label,
    required DateTime date,
    required TimeOfDay time,
    required VoidCallback onDateTap,
    VoidCallback? onTimeTap,
    required ColorScheme cs,
    required MeowExtras extras,
  }) {
    final dateStr = '${date.day}/${date.month}/${date.year}';
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: GestureDetector(
            onTap: onDateTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: extras.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: extras.subtleBorder),
              ),
              child: Text(
                dateStr,
                style: TextStyle(fontSize: 13, color: cs.onSurface),
              ),
            ),
          ),
        ),
        if (onTimeTap != null) ...[
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onTimeTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: extras.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: extras.subtleBorder),
              ),
              child: Text(
                timeStr,
                style: TextStyle(fontSize: 13, color: cs.onSurface),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
