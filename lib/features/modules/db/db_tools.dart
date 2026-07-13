import 'dart:convert';

import '../../../services/agent_runtime/runtime_models.dart';
import '../data/module_repository.dart';
import 'user_db_repository.dart';

/// Executes user-database-related tool calls.
class DbTools {
  DbTools({UserDbRepository? repository, ModuleRepository? moduleRepository})
    : _repo = repository ?? UserDbRepository(),
      _moduleRepository = moduleRepository ?? ModuleRepository();

  final UserDbRepository _repo;
  final ModuleRepository _moduleRepository;

  /// Check if the database module is enabled and a specific setting is allowed.
  Future<bool> _isAllowed(String settingKey) async {
    final modules = await _moduleRepository.getInstalled();
    final dbMod = modules.where((m) => m.id == 'database').firstOrNull;
    if (dbMod == null || !dbMod.enabled) return false;
    return dbMod.settings[settingKey] ?? true;
  }

  Future<ToolExecutionResult> executeListTables(
    Map<String, dynamic> args,
  ) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'db.list_tables',
        error: 'Database module is disabled or read not allowed.',
      );
    }
    try {
      final tables = await _repo.listTables();
      return ToolExecutionResult(
        success: true,
        toolName: 'db.list_tables',
        data: {'tables': tables.map((t) => t.toJson()).toList()},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'db.list_tables',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeDescribeTable(
    Map<String, dynamic> args,
  ) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'db.describe_table',
        error: 'Database module is disabled or read not allowed.',
      );
    }
    try {
      final tableName = args['table'] as String? ?? '';
      if (tableName.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'db.describe_table',
          error: 'table argument is required.',
        );
      }
      final info = await _repo.describeTable(tableName);
      if (info == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'db.describe_table',
          error: 'Table not found: $tableName',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'db.describe_table',
        data: {'table': info.toJson()},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'db.describe_table',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeCreateTable(
    Map<String, dynamic> args,
  ) async {
    if (!await _isAllowed('allow_create_table')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'db.create_table',
        error: 'Database module is disabled or creating tables is not allowed.',
      );
    }
    try {
      final tableName = args['table'] as String? ?? '';
      final colsRaw = args['columns'] as List? ?? [];
      if (tableName.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'db.create_table',
          error: 'table name is required.',
        );
      }
      if (colsRaw.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'db.create_table',
          error: 'columns specification is required.',
        );
      }

      final columns = <UserTableColumn>[];
      for (final col in colsRaw) {
        if (col is Map<String, dynamic>) {
          columns.add(UserTableColumn.fromJson(col));
        } else {
          return const ToolExecutionResult(
            success: false,
            toolName: 'db.create_table',
            error: 'Invalid column specification format.',
          );
        }
      }

      final res = await _repo.createTable(tableName, columns);
      if (!res.created) {
        return ToolExecutionResult(
          success: false,
          toolName: 'db.create_table',
          error: res.error ?? 'Failed to create table.',
        );
      }
      final persisted = await _repo.describeTable(tableName);
      final expectedColumns = columns.map((column) => column.name).toSet();
      final actualColumns =
          persisted?.columns.map((column) => column.name).toSet() ?? const {};
      final verifiedColumns = expectedColumns.every(actualColumns.contains)
          ? expectedColumns.length
          : 0;

      return ToolExecutionResult(
        success: true,
        toolName: 'db.create_table',
        data: {
          'created': true,
          'table': persisted?.name ?? tableName,
          'persisted': persisted != null,
          'verifiedColumns': verifiedColumns,
        },
        actions: const [
          ResultAction(
            label: 'Open Database Manager',
            icon: 'database_outlined',
            type: 'navigate',
            target: '/database',
          ),
        ],
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'db.create_table',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeDropTable(
    Map<String, dynamic> args,
  ) async {
    if (!await _isAllowed('allow_drop_table')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'db.drop_table',
        error: 'Database module is disabled or dropping tables is not allowed.',
      );
    }
    try {
      final tableName = args['table'] as String? ?? '';
      if (tableName.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'db.drop_table',
          error: 'table name is required.',
        );
      }
      final res = await _repo.dropTable(tableName);
      if (!res.dropped) {
        return ToolExecutionResult(
          success: false,
          toolName: 'db.drop_table',
          error: res.error ?? 'Failed to drop table.',
        );
      }
      final persisted = await _repo.describeTable(tableName);
      return ToolExecutionResult(
        success: true,
        toolName: 'db.drop_table',
        data: {
          'dropped': true,
          'table': tableName,
          'absent': persisted == null,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'db.drop_table',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeInsert(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_write')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'db.insert',
        error: 'Database module is disabled or write not allowed.',
      );
    }
    try {
      final tableName = args['table'] as String? ?? '';
      final data = args['data'] as Map<String, dynamic>? ?? {};
      if (tableName.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'db.insert',
          error: 'table name is required.',
        );
      }
      if (data.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'db.insert',
          error: 'data is required.',
        );
      }

      final res = await _repo.insert(tableName, data);
      if (res.id == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'db.insert',
          error: res.error ?? 'Failed to insert row.',
        );
      }
      final persisted = await _repo.rowById(tableName, res.id!);
      final allFieldsMatch =
          persisted.row != null && _storedDataMatches(persisted.row!, data);
      return ToolExecutionResult(
        success: true,
        toolName: 'db.insert',
        data: {
          'inserted': true,
          'id': res.id,
          'table': tableName,
          'persisted': allFieldsMatch,
          'verifiedFields': allFieldsMatch ? data.length : 0,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'db.insert',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeQuery(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_read')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'db.query',
        error: 'Database module is disabled or read not allowed.',
      );
    }
    try {
      final sql = args['sql'] as String? ?? '';
      final params = args['params'] as List? ?? [];
      if (sql.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'db.query',
          error: 'sql statement is required.',
        );
      }

      final res = await _repo.query(sql, params: params);
      if (res.rows == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'db.query',
          error: res.error ?? 'Failed to execute query.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'db.query',
        data: {'rows': res.rows},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'db.query',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeUpdate(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_write')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'db.update',
        error: 'Database module is disabled or write not allowed.',
      );
    }
    try {
      final tableName = args['table'] as String? ?? '';
      final data = args['data'] as Map<String, dynamic>? ?? {};
      final whereClause = args['where'] as String? ?? '';
      final whereArgs = args['whereArgs'] as List? ?? [];

      if (tableName.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'db.update',
          error: 'table name is required.',
        );
      }
      if (data.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'db.update',
          error: 'data is required.',
        );
      }
      if (whereClause.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'db.update',
          error: 'where clause is required.',
        );
      }

      final targetIds = await _repo.rowIdsMatching(
        tableName,
        whereClause: whereClause,
        whereArgs: whereArgs,
      );
      final res = await _repo.update(
        tableName,
        data,
        whereClause: whereClause,
        whereArgs: whereArgs,
      );
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'db.update',
          error: res.error,
        );
      }
      var verifiedRows = 0;
      final ids = targetIds.ids ?? const <String>[];
      if (res.updated > 0 && ids.isNotEmpty) {
        for (final id in ids) {
          final persisted = await _repo.rowById(tableName, id);
          if (persisted.row != null &&
              _storedDataMatches(persisted.row!, data)) {
            verifiedRows++;
          }
        }
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'db.update',
        data: {
          'updated': res.updated,
          'table': tableName,
          'verifiedRows': verifiedRows == res.updated ? verifiedRows : 0,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'db.update',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeDelete(Map<String, dynamic> args) async {
    if (!await _isAllowed('allow_write')) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'db.delete',
        error: 'Database module is disabled or write not allowed.',
      );
    }
    try {
      final tableName = args['table'] as String? ?? '';
      final whereClause = args['where'] as String? ?? '';
      final whereArgs = args['whereArgs'] as List? ?? [];

      if (tableName.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'db.delete',
          error: 'table name is required.',
        );
      }
      if (whereClause.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'db.delete',
          error: 'where clause is required.',
        );
      }

      final targetIds = await _repo.rowIdsMatching(
        tableName,
        whereClause: whereClause,
        whereArgs: whereArgs,
      );
      final res = await _repo.delete(
        tableName,
        whereClause: whereClause,
        whereArgs: whereArgs,
      );
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'db.delete',
          error: res.error,
        );
      }
      var verifiedDeleted = 0;
      final ids = targetIds.ids ?? const <String>[];
      if (res.deleted > 0 && ids.isNotEmpty) {
        for (final id in ids) {
          final persisted = await _repo.rowById(tableName, id);
          if (persisted.row == null) verifiedDeleted++;
        }
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'db.delete',
        data: {
          'deleted': res.deleted,
          'table': tableName,
          'verifiedDeleted': verifiedDeleted == res.deleted
              ? verifiedDeleted
              : 0,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'db.delete',
        error: e.toString(),
      );
    }
  }

  bool _storedDataMatches(
    Map<String, dynamic> stored,
    Map<String, dynamic> expected,
  ) {
    if (expected.isEmpty) return false;
    for (final entry in expected.entries) {
      if (!stored.containsKey(entry.key)) return false;
      if (!_valuesMatch(_storedValue(entry.value), stored[entry.key])) {
        return false;
      }
    }
    return true;
  }

  Object? _storedValue(Object? value) {
    if (value is Map || value is List) return jsonEncode(value);
    return value;
  }

  bool _valuesMatch(Object? expected, Object? actual) {
    if (expected == actual) return true;
    if (expected is num && actual is num) return expected == actual;
    if (expected == null || actual == null) return false;
    return expected.toString().trim() == actual.toString().trim();
  }
}
