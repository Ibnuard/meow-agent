import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'meow_database.dart';
import 'meow_database_provider.dart';

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// Structured identity for an agent. Replaces SOUL.md.
///
/// All fields are nullable — the runtime treats null as "not set" and falls
/// back to defaults when building LLM context. This keeps the model close to
/// the storage shape and avoids special "empty string vs null" gymnastics.
class AgentSoul {
  const AgentSoul({
    required this.agentId,
    this.userName,
    this.userNickname,
    this.preferredLanguage,
    this.timezone,
    this.workRole,
    this.mainProject,
    this.communicationStyle,
    this.designPreference,
    this.persona,
    this.personaMeta,
    required this.updatedAt,
  });

  final String agentId;
  final String? userName;
  final String? userNickname;
  final String? preferredLanguage;
  final String? timezone;
  final String? workRole;
  final String? mainProject;
  final String? communicationStyle;
  final String? designPreference;
  final String? persona;
  final Map<String, dynamic>? personaMeta;
  final DateTime updatedAt;

  AgentSoul copyWith({
    String? userName,
    String? userNickname,
    String? preferredLanguage,
    String? timezone,
    String? workRole,
    String? mainProject,
    String? communicationStyle,
    String? designPreference,
    String? persona,
    Map<String, dynamic>? personaMeta,
    DateTime? updatedAt,
  }) {
    return AgentSoul(
      agentId: agentId,
      userName: userName ?? this.userName,
      userNickname: userNickname ?? this.userNickname,
      preferredLanguage: preferredLanguage ?? this.preferredLanguage,
      timezone: timezone ?? this.timezone,
      workRole: workRole ?? this.workRole,
      mainProject: mainProject ?? this.mainProject,
      communicationStyle: communicationStyle ?? this.communicationStyle,
      designPreference: designPreference ?? this.designPreference,
      persona: persona ?? this.persona,
      personaMeta: personaMeta ?? this.personaMeta,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toRow() => {
    'agent_id': agentId,
    'user_name': userName,
    'user_nickname': userNickname,
    'preferred_language': preferredLanguage,
    'timezone': timezone,
    'work_role': workRole,
    'main_project': mainProject,
    'communication_style': communicationStyle,
    'design_preference': designPreference,
    'persona': persona,
    'persona_meta': personaMeta == null ? null : jsonEncode(personaMeta),
    'updated_at': updatedAt.toIso8601String(),
  };

  /// CamelCase JSON shape used for profile import/export. Distinct from
  /// [toRow] which targets the SQLite schema (snake_case).
  Map<String, dynamic> toJson() => {
    'agentId': agentId,
    'userName': userName,
    'userNickname': userNickname,
    'preferredLanguage': preferredLanguage,
    'timezone': timezone,
    'workRole': workRole,
    'mainProject': mainProject,
    'communicationStyle': communicationStyle,
    'designPreference': designPreference,
    'persona': persona,
    'personaMeta': personaMeta,
    'updatedAt': updatedAt.toIso8601String(),
  };

  /// Read a soul from the camelCase JSON produced by [toJson]. Tolerant of
  /// missing or null fields so partial backups still round-trip cleanly.
  factory AgentSoul.fromJson(Map<String, dynamic> json) {
    final metaRaw = json['personaMeta'];
    Map<String, dynamic>? meta;
    if (metaRaw is Map) {
      meta = Map<String, dynamic>.from(metaRaw);
    }
    final updatedAtRaw = json['updatedAt'] as String?;
    return AgentSoul(
      agentId: (json['agentId'] as String?) ?? '',
      userName: json['userName'] as String?,
      userNickname: json['userNickname'] as String?,
      preferredLanguage: json['preferredLanguage'] as String?,
      timezone: json['timezone'] as String?,
      workRole: json['workRole'] as String?,
      mainProject: json['mainProject'] as String?,
      communicationStyle: json['communicationStyle'] as String?,
      designPreference: json['designPreference'] as String?,
      persona: json['persona'] as String?,
      personaMeta: meta,
      updatedAt: updatedAtRaw != null
          ? (DateTime.tryParse(updatedAtRaw) ?? DateTime.now())
          : DateTime.now(),
    );
  }

  factory AgentSoul.fromRow(Map<String, dynamic> row) {
    final metaRaw = row['persona_meta'] as String?;
    Map<String, dynamic>? meta;
    if (metaRaw != null && metaRaw.isNotEmpty) {
      try {
        meta = jsonDecode(metaRaw) as Map<String, dynamic>;
      } catch (_) {
        meta = null;
      }
    }
    return AgentSoul(
      agentId: row['agent_id'] as String,
      userName: row['user_name'] as String?,
      userNickname: row['user_nickname'] as String?,
      preferredLanguage: row['preferred_language'] as String?,
      timezone: row['timezone'] as String?,
      workRole: row['work_role'] as String?,
      mainProject: row['main_project'] as String?,
      communicationStyle: row['communication_style'] as String?,
      designPreference: row['design_preference'] as String?,
      persona: row['persona'] as String?,
      personaMeta: meta,
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }
}

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

/// Reactive identity store, one row per agent. Replaces SOUL.md file I/O.
///
/// Fields update individually (`updateField`) so the LLM-driven
/// `system.profile.update` tool can change a single attribute without
/// reading-modifying-writing the whole document.
class AgentSoulRepository {
  AgentSoulRepository(this._db);

  /// Canonical list of profile field keys the LLM can update via
  /// `system.profile.update`. Single source of truth — both the tool
  /// schema (`system.workspace.schema`) and the validator
  /// (`system.profile.update`) read from here so they cannot drift.
  static const List<String> profileFields = [
    'name',
    'nickname',
    'preferred_language',
    'timezone',
    'work_role',
    'main_project',
    'communication_style',
    'design_preference',
    'persona',
  ];

  /// Categories accepted by `system.memory.append`. Single source of truth
  /// shared between the schema-advertising tool and the validator.
  static const List<String> memoryCategories = [
    'fact',
    'preference',
    'bookmark',
    'session',
  ];

  final MeowDatabase _db;
  final _byAgentControllers = <String, StreamController<AgentSoul?>>{};

  /// In-memory soul cache. The runtime reads the soul on EVERY turn (once at
  /// the top of `run()` and again inside `WorkspaceContextBuilder.build`).
  /// Without this cache each turn = 2 DB round-trips for the same row that
  /// rarely changes. The cache is invalidated on any write (updateField /
  /// updateAll) and by [invalidate]. The provider prompt-cache also benefits
  /// because the stable context prefix stays byte-identical across turns
  /// when the soul hasn't changed.
  final _soulCache = <String, AgentSoul?>{};

  /// Clear the cached soul for [agentId] (or all agents when null). Call this
  /// when the soul is known to have changed externally.
  void invalidate([String? agentId]) {
    if (agentId == null) {
      _soulCache.clear();
    } else {
      _soulCache.remove(agentId);
    }
  }

  /// Watch a specific agent's soul row.
  Stream<AgentSoul?> watch(String agentId) async* {
    yield await get(agentId);
    final ctrl = _byAgentControllers.putIfAbsent(
      agentId,
      () => StreamController<AgentSoul?>.broadcast(),
    );
    yield* ctrl.stream;
  }

  Future<AgentSoul?> get(String agentId) async {
    if (_soulCache.containsKey(agentId)) {
      return _soulCache[agentId];
    }
    final db = await _db.database;
    final rows = await db.query(
      'agent_soul',
      where: 'agent_id = ?',
      whereArgs: [agentId],
    );
    final soul = rows.isEmpty ? null : AgentSoul.fromRow(rows.first);
    _soulCache[agentId] = soul;
    return soul;
  }

  /// Update a single field. Used by `system.profile.update`.
  ///
  /// Allowed [field] values:
  /// `name` (→ user_name), `nickname` (→ user_nickname),
  /// `preferred_language`, `timezone`, `work_role`, `main_project`,
  /// `communication_style`, `design_preference`, `persona`.
  Future<AgentSoul> updateField({
    required String agentId,
    required String field,
    required String value,
  }) async {
    final column = _columnForField(field);
    if (column == null) {
      throw ArgumentError('Unknown soul field: $field');
    }
    final now = DateTime.now();
    final db = await _db.database;
    await db.update(
      'agent_soul',
      {column: value, 'updated_at': now.toIso8601String()},
      where: 'agent_id = ?',
      whereArgs: [agentId],
    );
    _soulCache.remove(agentId);
    final fresh = await get(agentId);
    if (fresh != null) _notify(agentId, fresh);
    return fresh!;
  }

  /// Update multiple fields atomically.
  Future<AgentSoul> updateAll(AgentSoul soul) async {
    final updated = soul.copyWith(updatedAt: DateTime.now());
    final db = await _db.database;
    await db.update(
      'agent_soul',
      updated.toRow(),
      where: 'agent_id = ?',
      whereArgs: [soul.agentId],
    );
    _soulCache[soul.agentId] = updated;
    _notify(soul.agentId, updated);
    return updated;
  }

  String? _columnForField(String field) {
    switch (field) {
      case 'name':
        return 'user_name';
      case 'nickname':
        return 'user_nickname';
      case 'user_name':
        return 'user_name';
      case 'user_nickname':
        return 'user_nickname';
      case 'preferred_language':
        return 'preferred_language';
      case 'timezone':
        return 'timezone';
      case 'work_role':
        return 'work_role';
      case 'main_project':
        return 'main_project';
      case 'communication_style':
        return 'communication_style';
      case 'design_preference':
        return 'design_preference';
      case 'persona':
        return 'persona';
      default:
        return null;
    }
  }

  void _notify(String agentId, AgentSoul soul) {
    _byAgentControllers[agentId]?.add(soul);
  }

  void dispose() {
    for (final c in _byAgentControllers.values) {
      c.close();
    }
    _byAgentControllers.clear();
  }
}

// ---------------------------------------------------------------------------
// Riverpod Providers
// ---------------------------------------------------------------------------

final agentSoulRepositoryProvider = Provider<AgentSoulRepository>((ref) {
  final db = ref.read(meowDatabaseProvider);
  final repo = AgentSoulRepository(db);
  ref.onDispose(repo.dispose);
  return repo;
});

/// Reactive stream of one agent's soul.
final agentSoulProvider = StreamProvider.family<AgentSoul?, String>((
  ref,
  agentId,
) {
  return ref.read(agentSoulRepositoryProvider).watch(agentId);
});
