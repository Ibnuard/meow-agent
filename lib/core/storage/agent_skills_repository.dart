import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import 'meow_database.dart';
import 'meow_database_provider.dart';

class AgentSkill {
  const AgentSkill({
    required this.id,
    required this.title,
    required this.content,
    this.githubUrl,
    required this.isEnabled,
    required this.createdAt,
    this.assignedAgentIds = const [],
  });

  final String id;
  final String title;
  final String content;
  final String? githubUrl;
  final bool isEnabled;
  final DateTime createdAt;
  final List<String> assignedAgentIds;

  AgentSkill copyWith({
    String? id,
    String? title,
    String? content,
    String? githubUrl,
    bool? isEnabled,
    DateTime? createdAt,
    List<String>? assignedAgentIds,
  }) {
    return AgentSkill(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      githubUrl: githubUrl ?? this.githubUrl,
      isEnabled: isEnabled ?? this.isEnabled,
      createdAt: createdAt ?? this.createdAt,
      assignedAgentIds: assignedAgentIds ?? this.assignedAgentIds,
    );
  }

  factory AgentSkill.fromRow(Map<String, dynamic> row, {List<String> assignedAgentIds = const []}) {
    return AgentSkill(
      id: row['id'] as String,
      title: row['title'] as String,
      content: row['content'] as String,
      githubUrl: row['github_url'] as String?,
      isEnabled: (row['is_enabled'] as int) == 1,
      createdAt: DateTime.parse(row['created_at'] as String),
      assignedAgentIds: assignedAgentIds,
    );
  }
}

class AgentSkillsRepository {
  AgentSkillsRepository(this._db);

  final MeowDatabase _db;
  final _changeController = StreamController<void>.broadcast();

  Stream<List<AgentSkill>> watchAll() async* {
    yield await getAll();
    await for (final _ in _changeController.stream) {
      yield await getAll();
    }
  }

  Stream<AgentSkill?> watchById(String id) async* {
    yield await getById(id);
    await for (final _ in _changeController.stream) {
      yield await getById(id);
    }
  }

  Future<List<AgentSkill>> getAll() async {
    final db = await _db.database;
    final rows = await db.query('agent_skills', orderBy: 'created_at DESC');
    
    final List<AgentSkill> skills = [];
    for (final row in rows) {
      final skillId = row['id'] as String;
      final assignments = await db.query(
        'agent_skill_assignments',
        where: 'skill_id = ?',
        whereArgs: [skillId],
      );
      final agentIds = assignments.map((r) => r['agent_id'] as String).toList();
      skills.add(AgentSkill.fromRow(row, assignedAgentIds: agentIds));
    }
    return skills;
  }

  Future<AgentSkill?> getById(String id) async {
    final db = await _db.database;
    final rows = await db.query(
      'agent_skills',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    
    final assignments = await db.query(
      'agent_skill_assignments',
      where: 'skill_id = ?',
      whereArgs: [id],
    );
    final agentIds = assignments.map((r) => r['agent_id'] as String).toList();
    return AgentSkill.fromRow(rows.first, assignedAgentIds: agentIds);
  }

  Future<List<AgentSkill>> getActiveSkillsForAgent(String agentId) async {
    final db = await _db.database;
    final rows = await db.rawQuery('''
      SELECT s.* FROM agent_skills s
      JOIN agent_skill_assignments a ON s.id = a.skill_id
      WHERE a.agent_id = ? AND s.is_enabled = 1
      ORDER BY s.created_at DESC
    ''', [agentId]);
    return rows.map((r) => AgentSkill.fromRow(r)).toList();
  }

  Future<void> save(AgentSkill skill) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.insert(
        'agent_skills',
        {
          'id': skill.id,
          'title': skill.title,
          'content': skill.content,
          'github_url': skill.githubUrl,
          'is_enabled': skill.isEnabled ? 1 : 0,
          'created_at': skill.createdAt.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // Refresh assignments
      await txn.delete(
        'agent_skill_assignments',
        where: 'skill_id = ?',
        whereArgs: [skill.id],
      );
      for (final agentId in skill.assignedAgentIds) {
        await txn.insert('agent_skill_assignments', {
          'skill_id': skill.id,
          'agent_id': agentId,
        });
      }
    });
    _changeController.add(null);
  }

  Future<void> delete(String id) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.delete(
        'agent_skill_assignments',
        where: 'skill_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'agent_skills',
        where: 'id = ?',
        whereArgs: [id],
      );
    });
    _changeController.add(null);
  }

  Future<void> toggleEnabled(String id, bool enabled) async {
    final db = await _db.database;
    await db.update(
      'agent_skills',
      {'is_enabled': enabled ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changeController.add(null);
  }

  void dispose() {
    _changeController.close();
  }
}

// ---------------------------------------------------------------------------
// Riverpod Providers
// ---------------------------------------------------------------------------

final agentSkillsRepositoryProvider = Provider<AgentSkillsRepository>((ref) {
  final db = ref.read(meowDatabaseProvider);
  final repo = AgentSkillsRepository(db);
  ref.onDispose(repo.dispose);
  return repo;
});

final agentSkillsStreamProvider = StreamProvider<List<AgentSkill>>((ref) {
  return ref.read(agentSkillsRepositoryProvider).watchAll();
});

final agentSkillDetailProvider = StreamProvider.family<AgentSkill?, String>((ref, id) {
  return ref.read(agentSkillsRepositoryProvider).watchById(id);
});
