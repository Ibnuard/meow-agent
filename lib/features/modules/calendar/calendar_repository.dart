import 'package:uuid/uuid.dart';

import 'calendar_database.dart';
import 'calendar_event_model.dart';

/// Repository for calendar event CRUD operations.
class CalendarRepository {
  final _uuid = const Uuid();

  /// Create a new event.
  Future<CalendarEvent> createEvent({
    required String title,
    String description = '',
    required DateTime startTime,
    DateTime? endTime,
    bool allDay = false,
    String? color,
    List<String> tags = const [],
    String source = 'user',
  }) async {
    final db = await CalendarDatabase.instance.database;
    final now = DateTime.now();
    final event = CalendarEvent(
      id: _uuid.v4(),
      title: title,
      description: description,
      startTime: startTime,
      endTime: endTime ?? startTime.add(const Duration(hours: 1)),
      allDay: allDay,
      color: color,
      tags: tags,
      source: source,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('calendar_events', event.toMap());
    return event;
  }

  /// Get a single event by ID.
  Future<CalendarEvent?> getEvent(String id) async {
    final db = await CalendarDatabase.instance.database;
    final rows = await db.query(
      'calendar_events',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return CalendarEvent.fromMap(rows.first);
  }

  /// List events within a date range.
  Future<List<CalendarEvent>> listEvents({
    required DateTime from,
    required DateTime to,
    int limit = 50,
  }) async {
    final db = await CalendarDatabase.instance.database;
    final rows = await db.query(
      'calendar_events',
      where: 'start_time < ? AND end_time > ?',
      whereArgs: [
        to.millisecondsSinceEpoch,
        from.millisecondsSinceEpoch,
      ],
      orderBy: 'start_time ASC',
      limit: limit,
    );
    return rows.map(CalendarEvent.fromMap).toList();
  }

  /// Get today's events.
  Future<List<CalendarEvent>> todayEvents() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));
    return listEvents(from: start, to: end);
  }

  /// Get events for a specific day.
  Future<List<CalendarEvent>> eventsForDay(DateTime day) async {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return listEvents(from: start, to: end);
  }

  /// Get days with events in a month (for dot indicators).
  Future<Set<int>> daysWithEventsInMonth(int year, int month) async {
    final from = DateTime(year, month, 1);
    final to = DateTime(year, month + 1, 1);
    final events = await listEvents(from: from, to: to, limit: 500);
    final days = <int>{};
    for (final e in events) {
      // Add all days the event spans.
      var d = e.startTime;
      while (d.isBefore(to) && !d.isAfter(e.endTime)) {
        if (d.month == month) days.add(d.day);
        d = d.add(const Duration(days: 1));
      }
    }
    return days;
  }

  /// Update an event.
  Future<void> updateEvent(
    String id, {
    String? title,
    String? description,
    DateTime? startTime,
    DateTime? endTime,
    bool? allDay,
    String? color,
    List<String>? tags,
  }) async {
    final db = await CalendarDatabase.instance.database;
    final updates = <String, dynamic>{
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (title != null) updates['title'] = title;
    if (description != null) updates['description'] = description;
    if (startTime != null) {
      updates['start_time'] = startTime.millisecondsSinceEpoch;
    }
    if (endTime != null) {
      updates['end_time'] = endTime.millisecondsSinceEpoch;
    }
    if (allDay != null) updates['all_day'] = allDay ? 1 : 0;
    if (color != null) updates['color'] = color;
    if (tags != null) updates['tags'] = tags.join(',');

    await db.update(
      'calendar_events',
      updates,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Delete an event.
  Future<void> deleteEvent(String id) async {
    final db = await CalendarDatabase.instance.database;
    await db.delete('calendar_events', where: 'id = ?', whereArgs: [id]);
  }
}
