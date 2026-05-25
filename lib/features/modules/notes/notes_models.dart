import 'dart:convert';

/// Represents a single note stored in SQLite.
class Note {
  const Note({
    required this.id,
    required this.title,
    required this.content,
    this.tags = const [],
    this.source = '',
    this.pinned = false,
    this.archived = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String content;
  final List<String> tags;
  final String source;
  final bool pinned;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;

  Note copyWith({
    String? id,
    String? title,
    String? content,
    List<String>? tags,
    String? source,
    bool? pinned,
    bool? archived,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Note(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      tags: tags ?? this.tags,
      source: source ?? this.source,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'tags': tags,
        'source': source,
        'pinned': pinned,
        'archived': archived,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  Map<String, dynamic> toDbMap() => {
        'id': id,
        'title': title,
        'content': content,
        'tags': jsonEncode(tags),
        'source': source,
        'pinned': pinned ? 1 : 0,
        'archived': archived ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory Note.fromDbMap(Map<String, dynamic> map) {
    List<String> parseTags(dynamic raw) {
      if (raw == null || raw == '') return [];
      try {
        final decoded = jsonDecode(raw as String);
        if (decoded is List) return decoded.cast<String>();
      } catch (_) {}
      return [];
    }

    return Note(
      id: map['id'] as String,
      title: map['title'] as String,
      content: map['content'] as String,
      tags: parseTags(map['tags']),
      source: map['source'] as String? ?? '',
      pinned: (map['pinned'] as int? ?? 0) == 1,
      archived: (map['archived'] as int? ?? 0) == 1,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt:
          DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }
}
