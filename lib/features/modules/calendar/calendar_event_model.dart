/// Data model for a calendar event.
class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.title,
    this.description = '',
    required this.startTime,
    required this.endTime,
    this.allDay = false,
    this.color,
    this.tags = const [],
    this.source = 'user',
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String description;
  final DateTime startTime;
  final DateTime endTime;
  final bool allDay;
  final String? color;
  final List<String> tags;
  final String source; // 'user' | 'agent'
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'description': description,
        'start_time': startTime.millisecondsSinceEpoch,
        'end_time': endTime.millisecondsSinceEpoch,
        'all_day': allDay ? 1 : 0,
        'color': color,
        'tags': tags.join(','),
        'source': source,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory CalendarEvent.fromMap(Map<String, dynamic> map) {
    return CalendarEvent(
      id: map['id'] as String,
      title: map['title'] as String? ?? '',
      description: map['description'] as String? ?? '',
      startTime:
          DateTime.fromMillisecondsSinceEpoch(map['start_time'] as int),
      endTime: DateTime.fromMillisecondsSinceEpoch(map['end_time'] as int),
      allDay: (map['all_day'] as int? ?? 0) == 1,
      color: map['color'] as String?,
      tags: (map['tags'] as String?)?.isNotEmpty == true
          ? (map['tags'] as String).split(',')
          : [],
      source: map['source'] as String? ?? 'user',
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt:
          DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }

  CalendarEvent copyWith({
    String? title,
    String? description,
    DateTime? startTime,
    DateTime? endTime,
    bool? allDay,
    String? color,
    List<String>? tags,
    DateTime? updatedAt,
  }) {
    return CalendarEvent(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      allDay: allDay ?? this.allDay,
      color: color ?? this.color,
      tags: tags ?? this.tags,
      source: source,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
