import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'user_database.dart';

/// Describes one column in a user table.
class UserTableColumn {
  const UserTableColumn({
    required this.name,
    required this.type,
    this.notNull = false,
    this.defaultValue,
  });

  final String name;

  /// SQLite affinity: TEXT, INTEGER, REAL, BLOB.
  final String type;
  final bool notNull;
  final String? defaultValue;

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'notNull': notNull,
    if (defaultValue != null) 'defaultValue': defaultValue,
  };

  factory UserTableColumn.fromJson(Map<String, dynamic> j) => UserTableColumn(
    name: j['name'] as String,
    type: j['type'] as String,
    notNull: j['notNull'] as bool? ?? false,
    defaultValue: j['defaultValue'] as String?,
  );
}

/// Metadata about a user-defined table, derived from sqlite_master.
class UserTableInfo {
  const UserTableInfo({
    required this.name,
    required this.columns,
    required this.rowCount,
  });

  final String name;
  final List<UserTableColumn> columns;
  final int rowCount;

  Map<String, dynamic> toJson() => {
    'name': name,
    'rowCount': rowCount,
    'columns': columns.map((c) => c.toJson()).toList(),
  };
}

/// Repository for all user-database operations.
///
/// Provides safe wrappers around raw SQLite so agent tools never need to
/// construct raw SQL strings themselves — the repository validates identifiers,
/// enforces reserved-name guardrails, and returns structured results.
class UserDbRepository {
  UserDbRepository();

  static const _uuid = Uuid();

  // Names the agent/user must not use (they'd collide with sqlite internals).
  static const _reservedPrefixes = ['sqlite_'];

  // ---------------------------------------------------------------------------
  // Schema operations
  // ---------------------------------------------------------------------------

  /// Returns all user-defined tables (excludes sqlite_* internal tables).
  Future<List<UserTableInfo>> listTables() async {
    final db = await UserDatabase.instance.database;
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata' "
      "ORDER BY name",
    );
    final tables = <UserTableInfo>[];
    for (final row in rows) {
      final name = row['name'] as String;
      tables.add(await _tableInfo(db, name));
    }
    return tables;
  }

  /// Returns column info + row count for a single table.
  Future<UserTableInfo?> describeTable(String tableName) async {
    if (!_validIdentifier(tableName)) return null;
    final db = await UserDatabase.instance.database;
    final resolvedName = await _resolveTableName(db, tableName);
    if (resolvedName == null) return null;
    return _tableInfo(db, resolvedName);
  }

  /// Creates a new table with the given columns.
  ///
  /// Always prepends a hidden `_id` TEXT PRIMARY KEY column (UUID) so rows
  /// always have a stable identifier regardless of what columns the agent
  /// defines. The agent does not see `_id` in normal query results — it's
  /// exposed only when the agent explicitly selects it.
  Future<({bool created, String? error})> createTable(
    String tableName,
    List<UserTableColumn> columns,
  ) async {
    if (!_validIdentifier(tableName)) {
      return (created: false, error: 'Invalid table name: $tableName');
    }
    if (_isReserved(tableName)) {
      return (created: false, error: 'Table name is reserved: $tableName');
    }
    if (columns.isEmpty) {
      return (created: false, error: 'At least one column is required.');
    }
    for (final col in columns) {
      if (!_validIdentifier(col.name)) {
        return (created: false, error: 'Invalid column name: ${col.name}');
      }
    }

    final db = await UserDatabase.instance.database;
    final exists = await _tableExists(db, tableName);
    if (exists) {
      return (created: false, error: 'Table already exists: $tableName');
    }

    final hasUserPk = columns.any(
      (c) => c.type.toUpperCase().contains('PRIMARY KEY'),
    );

    final colDefs = [
      hasUserPk ? '_id TEXT NOT NULL' : '_id TEXT PRIMARY KEY',
      '_created_at INTEGER NOT NULL',
      for (final col in columns)
        '${_q(col.name)} ${_safeType(col.type)}'
            '${col.type.toUpperCase().contains('PRIMARY KEY') ? ' PRIMARY KEY' : ''}'
            '${col.notNull ? ' NOT NULL' : ''}'
            '${col.defaultValue != null ? " DEFAULT ${col.defaultValue}" : ''}',
    ].join(', ');

    await db.execute('CREATE TABLE ${_q(tableName)} ($colDefs)');
    return (created: true, error: null);
  }

  /// Drops a table permanently.
  Future<({bool dropped, String? error})> dropTable(String tableName) async {
    if (!_validIdentifier(tableName)) {
      return (dropped: false, error: 'Invalid table name: $tableName');
    }
    final db = await UserDatabase.instance.database;
    final resolvedName = await _resolveTableName(db, tableName);
    if (resolvedName == null) {
      return (dropped: false, error: 'Table not found: $tableName');
    }
    await db.execute('DROP TABLE ${_q(resolvedName)}');
    return (dropped: true, error: null);
  }

  // ---------------------------------------------------------------------------
  // Data operations
  // ---------------------------------------------------------------------------

  /// Inserts a row. Returns the generated `_id`.
  Future<({String? id, String? error})> insert(
    String tableName,
    Map<String, dynamic> data,
  ) async {
    if (!_validIdentifier(tableName)) {
      return (id: null, error: 'Invalid table name: $tableName');
    }
    final db = await UserDatabase.instance.database;
    final resolvedName = await _resolveTableName(db, tableName);
    if (resolvedName == null) {
      return (id: null, error: 'Table not found: $tableName');
    }

    final id = 'row_${_uuid.v4().substring(0, 12)}';
    final sanitized = _sanitizeData(data);
    sanitized['_id'] = id;
    sanitized['_created_at'] = DateTime.now().millisecondsSinceEpoch;

    try {
      await db.insert(resolvedName, sanitized);
      return (id: id, error: null);
    } catch (e) {
      return (id: null, error: e.toString());
    }
  }

  /// Runs a raw SELECT and returns rows as JSON-serializable maps.
  ///
  /// Only SELECT statements are allowed — any other statement type is rejected.
  Future<({List<Map<String, dynamic>>? rows, String? error})> query(
    String sql, {
    List<dynamic> params = const [],
  }) async {
    final trimmed = sql.trim().toUpperCase();
    if (!trimmed.startsWith('SELECT')) {
      return (rows: null, error: 'Only SELECT queries are allowed.');
    }
    final db = await UserDatabase.instance.database;
    try {
      final rows = await db.rawQuery(sql, params.isEmpty ? null : params);
      return (rows: rows.toList(), error: null);
    } catch (e) {
      return (rows: null, error: e.toString());
    }
  }

  /// Updates rows matching [whereClause] in [tableName].
  Future<({int updated, String? error})> update(
    String tableName,
    Map<String, dynamic> data, {
    required String whereClause,
    required List<dynamic> whereArgs,
  }) async {
    if (!_validIdentifier(tableName)) {
      return (updated: 0, error: 'Invalid table name: $tableName');
    }
    final db = await UserDatabase.instance.database;
    final resolvedName = await _resolveTableName(db, tableName);
    if (resolvedName == null) {
      return (updated: 0, error: 'Table not found: $tableName');
    }
    try {
      final count = await db.update(
        resolvedName,
        _sanitizeData(data),
        where: whereClause,
        whereArgs: whereArgs,
      );
      return (updated: count, error: null);
    } catch (e) {
      return (updated: 0, error: e.toString());
    }
  }

  /// Deletes rows matching [whereClause].
  Future<({int deleted, String? error})> delete(
    String tableName, {
    required String whereClause,
    required List<dynamic> whereArgs,
  }) async {
    if (!_validIdentifier(tableName)) {
      return (deleted: 0, error: 'Invalid table name: $tableName');
    }
    final db = await UserDatabase.instance.database;
    final resolvedName = await _resolveTableName(db, tableName);
    if (resolvedName == null) {
      return (deleted: 0, error: 'Table not found: $tableName');
    }
    try {
      final count = await db.delete(
        resolvedName,
        where: whereClause,
        whereArgs: whereArgs,
      );
      return (deleted: count, error: null);
    } catch (e) {
      return (deleted: 0, error: e.toString());
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<bool> _tableExists(dynamic db, String name) async {
    return await _resolveTableName(db, name) != null;
  }

  /// Resolve a user-supplied identifier to SQLite's canonical stored casing.
  /// SQLite identifiers are case-insensitive, so repository pre-checks must
  /// follow the same rule instead of rejecting `fabel` when `Fabel` exists.
  Future<String?> _resolveTableName(dynamic db, String name) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type='table' AND name = ? COLLATE NOCASE LIMIT 1",
      [name],
    );
    if (rows.isEmpty) return null;
    return rows.first['name']?.toString();
  }

  Future<UserTableInfo> _tableInfo(dynamic db, String name) async {
    // PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
    final pragma = await db.rawQuery('PRAGMA table_info(${_q(name)})');
    final columns = <UserTableColumn>[];
    for (final row in pragma) {
      final colName = row['name'] as String;
      // Hide internal columns from the agent surface.
      if (colName == '_id' || colName == '_created_at') continue;
      columns.add(
        UserTableColumn(
          name: colName,
          type: (row['type'] as String? ?? 'TEXT').toUpperCase(),
          notNull: (row['notnull'] as int? ?? 0) == 1,
          defaultValue: row['dflt_value'] as String?,
        ),
      );
    }
    final countRow = await db.rawQuery('SELECT COUNT(*) as c FROM ${_q(name)}');
    final rowCount = (countRow.first['c'] as int?) ?? 0;
    return UserTableInfo(name: name, columns: columns, rowCount: rowCount);
  }

  /// Quotes an identifier safely.
  String _q(String name) => '"$name"';

  /// Validates that an identifier contains only safe characters.
  bool _validIdentifier(String name) =>
      name.isNotEmpty && RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(name);

  bool _isReserved(String name) =>
      _reservedPrefixes.any((p) => name.toLowerCase().startsWith(p));

  /// Maps user-supplied type strings to safe SQLite affinity tokens.
  String _safeType(String type) {
    final upper = type.toUpperCase();
    if (upper.contains('INT')) {
      return 'INTEGER';
    }
    if (upper.contains('REAL') ||
        upper.contains('FLOAT') ||
        upper.contains('DOUBLE')) {
      return 'REAL';
    }
    if (upper.contains('BLOB')) {
      return 'BLOB';
    }
    return 'TEXT';
  }

  /// Removes any attempt to set internal columns via data map.
  Map<String, dynamic> _sanitizeData(Map<String, dynamic> data) {
    final result = <String, dynamic>{};
    for (final entry in data.entries) {
      if (entry.key == '_id' || entry.key == '_created_at') continue;
      // Encode nested objects/lists as JSON strings.
      final v = entry.value;
      result[entry.key] = (v is Map || v is List) ? jsonEncode(v) : v;
    }
    return result;
  }
}
