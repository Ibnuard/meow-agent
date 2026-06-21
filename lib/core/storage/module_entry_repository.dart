import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import 'meow_database.dart';
import 'meow_database_provider.dart';

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// A registered module / plugin.
class ModuleEntry {
  const ModuleEntry({
    required this.id,
    this.enabled = true,
    this.config,
    required this.installedAt,
  });

  final String id;
  final bool enabled;
  final Map<String, dynamic>? config;
  final DateTime installedAt;

  ModuleEntry copyWith({bool? enabled, Map<String, dynamic>? config}) =>
      ModuleEntry(
        id: id,
        enabled: enabled ?? this.enabled,
        config: config ?? this.config,
        installedAt: installedAt,
      );

  Map<String, dynamic> toRow() => {
    'id': id,
    'enabled': enabled ? 1 : 0,
    'config_json': config == null ? null : jsonEncode(config),
    'installed_at': installedAt.toIso8601String(),
  };

  factory ModuleEntry.fromRow(Map<String, dynamic> row) {
    final cfgRaw = row['config_json'] as String?;
    Map<String, dynamic>? cfg;
    if (cfgRaw != null && cfgRaw.isNotEmpty) {
      try {
        cfg = jsonDecode(cfgRaw) as Map<String, dynamic>;
      } catch (_) {
        cfg = null;
      }
    }
    return ModuleEntry(
      id: row['id'] as String,
      enabled: (row['enabled'] as int?) != 0,
      config: cfg,
      installedAt: DateTime.parse(row['installed_at'] as String),
    );
  }
}

/// Per-agent module permission and override config.
class AgentModulePermission {
  const AgentModulePermission({
    required this.agentId,
    required this.moduleId,
    this.enabled = true,
    this.config,
  });

  final String agentId;
  final String moduleId;
  final bool enabled;
  final Map<String, dynamic>? config;

  Map<String, dynamic> toRow() => {
    'agent_id': agentId,
    'module_id': moduleId,
    'enabled': enabled ? 1 : 0,
    'config_json': config == null ? null : jsonEncode(config),
  };

  factory AgentModulePermission.fromRow(Map<String, dynamic> row) {
    final cfgRaw = row['config_json'] as String?;
    Map<String, dynamic>? cfg;
    if (cfgRaw != null && cfgRaw.isNotEmpty) {
      try {
        cfg = jsonDecode(cfgRaw) as Map<String, dynamic>;
      } catch (_) {
        cfg = null;
      }
    }
    return AgentModulePermission(
      agentId: row['agent_id'] as String,
      moduleId: row['module_id'] as String,
      enabled: (row['enabled'] as int?) != 0,
      config: cfg,
    );
  }
}

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

/// Module registry + per-agent permission store.
///
/// Module registration (the global table) happens at app boot — runtime
/// plugin discovery upserts each known module so the DB always reflects the
/// installed plugin set. Per-agent permissions are independent and let users
/// disable specific tools for specific agents.
class ModuleEntryRepository {
  ModuleEntryRepository(this._db);

  final MeowDatabase _db;
  final _allController = StreamController<List<ModuleEntry>>.broadcast();
  final _permControllers =
      <String, StreamController<List<AgentModulePermission>>>{};

  Stream<List<ModuleEntry>> watchAll() async* {
    yield await listAll();
    yield* _allController.stream;
  }

  Stream<List<AgentModulePermission>> watchPermissions(String agentId) async* {
    yield await listPermissions(agentId);
    final ctrl = _permControllers.putIfAbsent(
      agentId,
      () => StreamController<List<AgentModulePermission>>.broadcast(),
    );
    yield* ctrl.stream;
  }

  Future<List<ModuleEntry>> listAll() async {
    final db = await _db.database;
    final rows = await db.query('modules', orderBy: 'installed_at ASC');
    return rows.map(ModuleEntry.fromRow).toList();
  }

  Future<ModuleEntry?> getById(String id) async {
    final db = await _db.database;
    final rows = await db.query('modules', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return ModuleEntry.fromRow(rows.first);
  }

  /// Upsert a module — used by plugin discovery at boot. Existing rows keep
  /// their `enabled` flag and `config` so user preferences are preserved
  /// across app restarts.
  Future<ModuleEntry> upsert(String id) async {
    final db = await _db.database;
    final existing = await getById(id);
    if (existing != null) return existing;
    final entry = ModuleEntry(id: id, installedAt: DateTime.now());
    await db.insert(
      'modules',
      entry.toRow(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    _notifyAll();
    return entry;
  }

  Future<ModuleEntry> setEnabled(String id, bool enabled) async {
    final db = await _db.database;
    await db.update(
      'modules',
      {'enabled': enabled ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifyAll();
    return (await getById(id))!;
  }

  Future<ModuleEntry> setConfig(String id, Map<String, dynamic>? config) async {
    final db = await _db.database;
    await db.update(
      'modules',
      {'config_json': config == null ? null : jsonEncode(config)},
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifyAll();
    return (await getById(id))!;
  }

  /// Remove a module entirely. Cascade-deletes agent_module_permissions via FK.
  Future<void> delete(String id) async {
    final db = await _db.database;
    await db.delete('modules', where: 'id = ?', whereArgs: [id]);
    _notifyAll();
  }

  Future<List<AgentModulePermission>> listPermissions(String agentId) async {
    final db = await _db.database;
    final rows = await db.query(
      'agent_module_permissions',
      where: 'agent_id = ?',
      whereArgs: [agentId],
    );
    return rows.map(AgentModulePermission.fromRow).toList();
  }

  Future<AgentModulePermission> setPermission({
    required String agentId,
    required String moduleId,
    required bool enabled,
    Map<String, dynamic>? config,
  }) async {
    final perm = AgentModulePermission(
      agentId: agentId,
      moduleId: moduleId,
      enabled: enabled,
      config: config,
    );
    final db = await _db.database;
    await db.insert(
      'agent_module_permissions',
      perm.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifyPerms(agentId);
    return perm;
  }

  Future<void> removePermission({
    required String agentId,
    required String moduleId,
  }) async {
    final db = await _db.database;
    await db.delete(
      'agent_module_permissions',
      where: 'agent_id = ? AND module_id = ?',
      whereArgs: [agentId, moduleId],
    );
    _notifyPerms(agentId);
  }

  void _notifyAll() async {
    _allController.add(await listAll());
  }

  void _notifyPerms(String agentId) async {
    final ctrl = _permControllers[agentId];
    if (ctrl == null) return;
    ctrl.add(await listPermissions(agentId));
  }

  void dispose() {
    _allController.close();
    for (final c in _permControllers.values) {
      c.close();
    }
    _permControllers.clear();
  }
}

// ---------------------------------------------------------------------------
// Riverpod Providers
// ---------------------------------------------------------------------------

final moduleEntryRepositoryProvider = Provider<ModuleEntryRepository>((ref) {
  final db = ref.read(meowDatabaseProvider);
  final repo = ModuleEntryRepository(db);
  ref.onDispose(repo.dispose);
  return repo;
});

final moduleEntryStreamProvider = StreamProvider<List<ModuleEntry>>((ref) {
  return ref.read(moduleEntryRepositoryProvider).watchAll();
});

final agentModulePermissionsProvider =
    StreamProvider.family<List<AgentModulePermission>, String>((ref, agentId) {
  return ref.read(moduleEntryRepositoryProvider).watchPermissions(agentId);
});
