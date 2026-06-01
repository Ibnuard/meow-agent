import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

import '../../../app/theme.dart';
import '../../settings/data/app_language_provider.dart';
import 'calendar_event_model.dart';
import 'calendar_repository.dart';
import 'calendar_event_editor.dart';

/// Provider for the calendar repository.
final calendarRepositoryProvider = Provider((_) => CalendarRepository());

/// Calendar screen — uses Syncfusion SfCalendar.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  List<CalendarEvent> _events = [];
  final CalendarController _calendarController = CalendarController();
  DateTime _selectedDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _calendarController.selectedDate = _selectedDate;
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    final repo = ref.read(calendarRepositoryProvider);
    // Load 3 months range around current date.
    final now = DateTime.now();
    final from = DateTime(now.year, now.month - 1, 1);
    final to = DateTime(now.year, now.month + 2, 0);
    final events = await repo.listEvents(from: from, to: to, limit: 500);
    if (mounted) setState(() => _events = events);
  }

  Future<void> _onViewChanged(ViewChangedDetails details) async {
    // Reload events when the visible date range changes.
    if (details.visibleDates.isEmpty) return;
    final first = details.visibleDates.first;
    final last = details.visibleDates.last;
    final repo = ref.read(calendarRepositoryProvider);
    final events = await repo.listEvents(
      from: first,
      to: last.add(const Duration(days: 1)),
      limit: 500,
    );
    if (mounted) setState(() => _events = events);
  }

  void _onTap(CalendarTapDetails details) {
    if (details.targetElement == CalendarElement.agenda ||
        details.targetElement == CalendarElement.appointment) {
      // Tapped on an appointment in agenda → edit it.
      if (details.appointments != null && details.appointments!.isNotEmpty) {
        final appointment = details.appointments!.first as Appointment;
        final event = _events.firstWhere(
          (e) => e.id == appointment.id,
          orElse: () => _events.first,
        );
        _openEditor(event: event);
      }
    } else if (details.targetElement == CalendarElement.calendarCell) {
      // Tapped on a cell → just select the date.
      if (details.date != null) {
        setState(() => _selectedDate = details.date!);
      }
    }
  }

  Future<void> _openEditor({CalendarEvent? event, DateTime? initialDate}) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CalendarEventEditor(
          event: event,
          initialDate: initialDate ?? DateTime.now(),
        ),
      ),
    );
    if (result == true) _loadEvents();
  }

  bool _isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    return Scaffold(
      appBar: AppBar(
        title: Text(s.calendarTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: s.calendarNewEvent,
            onPressed: () => _openEditor(initialDate: _selectedDate),
          ),
        ],
      ),
      body: SafeArea(
        child: Localizations.override(
          context: context,
          locale: Locale(s.isId ? 'id' : 'en'),
          child: SfCalendar(
          controller: _calendarController,
          view: CalendarView.month,
          dataSource: _MeowCalendarDataSource(_events, cs),
          onViewChanged: _onViewChanged,
          onTap: _onTap,
          firstDayOfWeek: 1, // Monday.
          showNavigationArrow: true,
          showDatePickerButton: true,
          monthViewSettings: MonthViewSettings(
            showAgenda: true,
            agendaViewHeight: 200,
            agendaStyle: AgendaStyle(
              backgroundColor: cs.surface,
              dayTextStyle: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
              dateTextStyle: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: cs.primary,
              ),
              appointmentTextStyle: TextStyle(
                fontSize: 13,
                color: cs.onSurface,
              ),
            ),
            monthCellStyle: MonthCellStyle(
              textStyle: TextStyle(fontSize: 13, color: cs.onSurface),
              trailingDatesTextStyle: TextStyle(
                fontSize: 13,
                color: cs.onSurfaceVariant.withValues(alpha: 0.4),
              ),
              leadingDatesTextStyle: TextStyle(
                fontSize: 13,
                color: cs.onSurfaceVariant.withValues(alpha: 0.4),
              ),
            ),
          ),
          monthCellBuilder: (context, details) {
            final isSunday = details.date.weekday == DateTime.sunday;
            final isToday = _isToday(details.date);
            final isCurrentMonth =
                details.date.month == details.visibleDates[15].month;

            Color textColor;
            if (!isCurrentMonth) {
              textColor = cs.onSurfaceVariant.withValues(alpha: 0.4);
            } else if (isSunday) {
              textColor = Colors.redAccent;
            } else {
              textColor = cs.onSurface;
            }

            return Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.08),
                  width: 0.5,
                ),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 4),
                  Container(
                    width: 24,
                    height: 24,
                    decoration: isToday
                        ? BoxDecoration(
                            color: cs.primary,
                            shape: BoxShape.circle,
                          )
                        : null,
                    alignment: Alignment.center,
                    child: Text(
                      '${details.date.day}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
                        color: isToday ? cs.onPrimary : textColor,
                      ),
                    ),
                  ),
                  if (details.appointments.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
          todayHighlightColor: cs.primary,
          selectionDecoration: BoxDecoration(
            border: Border.all(color: cs.primary, width: 1.5),
            borderRadius: BorderRadius.circular(6),
          ),
          headerStyle: CalendarHeaderStyle(
            textStyle: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
            backgroundColor: Colors.transparent,
          ),
          viewHeaderStyle: ViewHeaderStyle(
            dayTextStyle: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: cs.onSurfaceVariant,
            ),
          ),
          backgroundColor: Colors.transparent,
          cellBorderColor: cs.onSurfaceVariant.withValues(alpha: 0.08),
          ),
        ),
      ),
    );
  }
}

/// Custom data source that maps CalendarEvent to Syncfusion Appointment.
class _MeowCalendarDataSource extends CalendarDataSource {
  _MeowCalendarDataSource(List<CalendarEvent> events, ColorScheme cs) {
    appointments = events.map((e) {
      final color = e.color != null
          ? Color(int.parse('FF${e.color!.replaceAll('#', '')}', radix: 16))
          : cs.primary;
      return Appointment(
        id: e.id,
        startTime: e.startTime,
        endTime: e.endTime,
        subject: e.title,
        notes: e.description,
        isAllDay: e.allDay,
        color: color,
      );
    }).toList();
  }
}
