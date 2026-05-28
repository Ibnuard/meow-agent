import '../../../services/agent_runtime/runtime_models.dart';
import '../data/module_repository.dart';
import 'calendar_repository.dart';

/// Executes calendar-related tool calls.
class CalendarTools {
  CalendarTools({
    CalendarRepository? repository,
    ModuleRepository? moduleRepository,
  }) : _repo = repository ?? CalendarRepository(),
       _moduleRepository = moduleRepository ?? ModuleRepository();

  final CalendarRepository _repo;
  final ModuleRepository _moduleRepository;

  Future<bool> _isAllowed(String settingKey) async {
    final modules = await _moduleRepository.getInstalled();
    final calMod = modules.where((m) => m.id == 'calendar').firstOrNull;
    if (calMod == null || !calMod.enabled) return false;
    return calMod.settings[settingKey] ?? true;
  }

  // ─── calendar.create ─────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeCreate(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_create')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'calendar.create',
        error: 'Calendar module is disabled or create not allowed.',
      );
    }
    try {
      final title = (args['title'] as String? ?? '').trim();
      if (title.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'calendar.create',
          error: 'title is required.',
        );
      }

      final startStr = args['startTime'] as String? ?? '';
      if (startStr.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'calendar.create',
          error: 'startTime is required (ISO8601).',
        );
      }

      final startTime = DateTime.tryParse(startStr);
      if (startTime == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'calendar.create',
          error: 'Invalid startTime format. Use ISO8601.',
        );
      }

      DateTime? endTime;
      final endStr = args['endTime'] as String?;
      if (endStr != null && endStr.isNotEmpty) {
        endTime = DateTime.tryParse(endStr);
      }

      final allDay = args['allDay'] as bool? ?? false;
      final color = args['color'] as String?;
      final tags = (args['tags'] as List?)?.cast<String>() ?? [];
      final description = args['description'] as String? ?? '';

      final event = await _repo.createEvent(
        title: title,
        description: description,
        startTime: startTime,
        endTime: endTime,
        allDay: allDay,
        color: color,
        tags: tags,
        source: 'agent',
      );

      return ToolExecutionResult(
        success: true,
        toolName: 'calendar.create',
        data: {
          'eventId': event.id,
          'title': event.title,
          'startTime': event.startTime.toIso8601String(),
          'endTime': event.endTime.toIso8601String(),
        },
        actions: const [
          ResultAction(
            label: 'Open Calendar',
            labelId: 'Buka Kalender',
            icon: 'calendar_month_rounded',
            type: 'navigate',
            target: '/modules/calendar',
          ),
        ],
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'calendar.create',
        error: e.toString(),
      );
    }
  }

  // ─── calendar.today ──────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeToday(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'calendar.today',
        error: 'Calendar module is disabled or read not allowed.',
      );
    }
    try {
      final events = await _repo.todayEvents();
      return ToolExecutionResult(
        success: true,
        toolName: 'calendar.today',
        data: {
          'date': DateTime.now().toIso8601String().split('T').first,
          'count': events.length,
          'events': events
              .map(
                (e) => {
                  'id': e.id,
                  'title': e.title,
                  'startTime': e.startTime.toIso8601String(),
                  'endTime': e.endTime.toIso8601String(),
                  'allDay': e.allDay,
                },
              )
              .toList(),
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'calendar.today',
        error: e.toString(),
      );
    }
  }

  // ─── calendar.list ───────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeList(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'calendar.list',
        error: 'Calendar module is disabled or read not allowed.',
      );
    }
    try {
      final fromStr = args['from'] as String? ?? '';
      final toStr = args['to'] as String? ?? '';

      if (fromStr.isEmpty || toStr.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'calendar.list',
          error: 'Both "from" and "to" are required (ISO8601).',
        );
      }

      final from = DateTime.tryParse(fromStr);
      final to = DateTime.tryParse(toStr);
      if (from == null || to == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'calendar.list',
          error: 'Invalid date format. Use ISO8601.',
        );
      }

      final limit = (args['limit'] as num?)?.toInt() ?? 20;
      final events = await _repo.listEvents(from: from, to: to, limit: limit);

      return ToolExecutionResult(
        success: true,
        toolName: 'calendar.list',
        data: {
          'from': fromStr,
          'to': toStr,
          'count': events.length,
          'events': events
              .map(
                (e) => {
                  'id': e.id,
                  'title': e.title,
                  'startTime': e.startTime.toIso8601String(),
                  'endTime': e.endTime.toIso8601String(),
                  'allDay': e.allDay,
                },
              )
              .toList(),
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'calendar.list',
        error: e.toString(),
      );
    }
  }

  // ─── calendar.read ───────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeRead(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'calendar.read',
        error: 'Calendar module is disabled or read not allowed.',
      );
    }
    try {
      final eventId = (args['eventId'] as String? ?? '').trim();
      if (eventId.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'calendar.read',
          error: 'eventId is required.',
        );
      }

      final event = await _repo.getEvent(eventId);
      if (event == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'calendar.read',
          error: 'Event not found: $eventId',
        );
      }

      return ToolExecutionResult(
        success: true,
        toolName: 'calendar.read',
        data: {
          'event': {
            'id': event.id,
            'title': event.title,
            'description': event.description,
            'startTime': event.startTime.toIso8601String(),
            'endTime': event.endTime.toIso8601String(),
            'allDay': event.allDay,
            'color': event.color,
            'tags': event.tags,
            'source': event.source,
            'createdAt': event.createdAt.toIso8601String(),
          },
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'calendar.read',
        error: e.toString(),
      );
    }
  }

  // ─── calendar.update ─────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeUpdate(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_update')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'calendar.update',
        error: 'Calendar module is disabled or update not allowed.',
      );
    }
    try {
      final eventId = (args['eventId'] as String? ?? '').trim();
      if (eventId.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'calendar.update',
          error: 'eventId is required.',
        );
      }

      final title = args['title'] as String?;
      final description = args['description'] as String?;
      final allDay = args['allDay'] as bool?;
      final color = args['color'] as String?;
      final tags = (args['tags'] as List?)?.cast<String>();

      DateTime? startTime;
      final startStr = args['startTime'] as String?;
      if (startStr != null) startTime = DateTime.tryParse(startStr);

      DateTime? endTime;
      final endStr = args['endTime'] as String?;
      if (endStr != null) endTime = DateTime.tryParse(endStr);

      await _repo.updateEvent(
        eventId,
        title: title,
        description: description,
        startTime: startTime,
        endTime: endTime,
        allDay: allDay,
        color: color,
        tags: tags,
      );

      return const ToolExecutionResult(
        success: true,
        toolName: 'calendar.update',
        data: {'updated': true},
        actions: [
          ResultAction(
            label: 'Open Calendar',
            labelId: 'Buka Kalender',
            icon: 'calendar_month_rounded',
            type: 'navigate',
            target: '/modules/calendar',
          ),
        ],
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'calendar.update',
        error: e.toString(),
      );
    }
  }

  // ─── calendar.delete ─────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeDelete(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_delete')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'calendar.delete',
        error: 'Calendar module is disabled or delete not allowed.',
      );
    }
    try {
      final eventId = (args['eventId'] as String? ?? '').trim();
      if (eventId.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'calendar.delete',
          error: 'eventId is required.',
        );
      }

      await _repo.deleteEvent(eventId);
      return const ToolExecutionResult(
        success: true,
        toolName: 'calendar.delete',
        data: {'deleted': true},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'calendar.delete',
        error: e.toString(),
      );
    }
  }

  // ─── calendar.upcoming ───────────────────────────────────────────────────

  Future<ToolExecutionResult> executeUpcoming(
    Map<String, dynamic> args,
  ) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'calendar.upcoming',
        error: 'Calendar module is disabled or read not allowed.',
      );
    }
    try {
      final days = (args['days'] as num?)?.toInt().clamp(1, 90) ?? 7;
      final now = DateTime.now();
      final until = now.add(Duration(days: days));
      final events =
          await _repo.listEvents(from: now, to: until, limit: 200);
      // Group by date for readability.
      final byDate = <String, List<Map<String, dynamic>>>{};
      for (final e in events) {
        final key = e.startTime.toIso8601String().split('T').first;
        byDate.putIfAbsent(key, () => []).add({
          'id': e.id,
          'title': e.title,
          'startTime': e.startTime.toIso8601String(),
          'endTime': e.endTime.toIso8601String(),
          'allDay': e.allDay,
        });
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'calendar.upcoming',
        data: {
          'days': days,
          'count': events.length,
          'byDate': byDate,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'calendar.upcoming',
        error: e.toString(),
      );
    }
  }

  // ─── calendar.conflicts ──────────────────────────────────────────────────

  Future<ToolExecutionResult> executeConflicts(
    Map<String, dynamic> args,
  ) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'calendar.conflicts',
        error: 'Calendar module is disabled or read not allowed.',
      );
    }
    try {
      final startStr = args['startTime'] as String? ?? '';
      final start = DateTime.tryParse(startStr);
      if (start == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'calendar.conflicts',
          error: 'startTime is required (ISO8601).',
        );
      }
      final durationMinutes =
          (args['durationMinutes'] as num?)?.toInt() ?? 60;
      final end = start.add(Duration(minutes: durationMinutes));
      final overlapping = await _repo.listEvents(from: start, to: end);
      return ToolExecutionResult(
        success: true,
        toolName: 'calendar.conflicts',
        data: {
          'startTime': start.toIso8601String(),
          'endTime': end.toIso8601String(),
          'hasConflict': overlapping.isNotEmpty,
          'count': overlapping.length,
          'conflicts': overlapping
              .map((e) => {
                    'id': e.id,
                    'title': e.title,
                    'startTime': e.startTime.toIso8601String(),
                    'endTime': e.endTime.toIso8601String(),
                  })
              .toList(),
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'calendar.conflicts',
        error: e.toString(),
      );
    }
  }

  // ─── calendar.free_slot ──────────────────────────────────────────────────

  Future<ToolExecutionResult> executeFreeSlot(
    Map<String, dynamic> args,
  ) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'calendar.free_slot',
        error: 'Calendar module is disabled or read not allowed.',
      );
    }
    try {
      final durationMinutes =
          (args['durationMinutes'] as num?)?.toInt() ?? 60;
      final withinDays =
          (args['withinDays'] as num?)?.toInt().clamp(1, 30) ?? 7;
      final dayStartHour =
          (args['dayStartHour'] as num?)?.toInt().clamp(0, 23) ?? 9;
      final dayEndHour =
          (args['dayEndHour'] as num?)?.toInt().clamp(1, 24) ?? 17;
      final maxResults =
          (args['maxResults'] as num?)?.toInt().clamp(1, 20) ?? 5;
      final now = DateTime.now();
      final until = now.add(Duration(days: withinDays));
      final events =
          await _repo.listEvents(from: now, to: until, limit: 500);
      final slots = <Map<String, dynamic>>[];
      DateTime cursor = now;
      // Walk forward day-by-day inside working hours.
      while (cursor.isBefore(until) && slots.length < maxResults) {
        final dayStart = DateTime(
          cursor.year,
          cursor.month,
          cursor.day,
          dayStartHour,
        );
        final dayEnd = DateTime(
          cursor.year,
          cursor.month,
          cursor.day,
          dayEndHour,
        );
        var slotStart = cursor.isAfter(dayStart) ? cursor : dayStart;
        // Round up to next 15 min mark.
        final mod = slotStart.minute % 15;
        if (mod != 0) {
          slotStart = slotStart.add(Duration(minutes: 15 - mod));
        }
        // Events for the day, sorted.
        final todayEvents = events
            .where((e) =>
                e.startTime.isBefore(dayEnd) && e.endTime.isAfter(dayStart))
            .toList()
          ..sort((a, b) => a.startTime.compareTo(b.startTime));
        for (final event in todayEvents) {
          if (slots.length >= maxResults) break;
          final gap = event.startTime.difference(slotStart);
          if (gap.inMinutes >= durationMinutes) {
            slots.add({
              'startTime': slotStart.toIso8601String(),
              'endTime': slotStart
                  .add(Duration(minutes: durationMinutes))
                  .toIso8601String(),
              'durationMinutes': durationMinutes,
            });
          }
          if (event.endTime.isAfter(slotStart)) {
            slotStart = event.endTime;
          }
        }
        // Trailing free time at end of day.
        if (slots.length < maxResults &&
            dayEnd.difference(slotStart).inMinutes >= durationMinutes) {
          slots.add({
            'startTime': slotStart.toIso8601String(),
            'endTime': slotStart
                .add(Duration(minutes: durationMinutes))
                .toIso8601String(),
            'durationMinutes': durationMinutes,
          });
        }
        cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'calendar.free_slot',
        data: {
          'durationMinutes': durationMinutes,
          'workingHours': '$dayStartHour:00–$dayEndHour:00',
          'count': slots.length,
          'slots': slots,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'calendar.free_slot',
        error: e.toString(),
      );
    }
  }

  // ─── calendar.link_note ──────────────────────────────────────────────────

  /// Associates a note with an event by adding a `note:<id>` tag.
  /// No new schema needed — we reuse the existing event tags column.
  Future<ToolExecutionResult> executeLinkNote(
    Map<String, dynamic> args,
  ) async {
    if (!await _isAllowed('allow_update')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'calendar.link_note',
        error: 'Calendar module is disabled or update not allowed.',
      );
    }
    try {
      final eventId = (args['eventId'] as String? ?? '').trim();
      final noteId = (args['noteId'] as String? ?? '').trim();
      if (eventId.isEmpty || noteId.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'calendar.link_note',
          error: 'eventId and noteId are required.',
        );
      }
      final event = await _repo.getEvent(eventId);
      if (event == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'calendar.link_note',
          error: 'Event not found: $eventId',
        );
      }
      final tag = 'note:$noteId';
      final newTags = {...event.tags, tag}.toList();
      await _repo.updateEvent(eventId, tags: newTags);
      return ToolExecutionResult(
        success: true,
        toolName: 'calendar.link_note',
        data: {
          'eventId': eventId,
          'noteId': noteId,
          'linkedTags': newTags,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'calendar.link_note',
        error: e.toString(),
      );
    }
  }
}
