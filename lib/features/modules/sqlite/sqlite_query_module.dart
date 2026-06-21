import 'package:sqflite/sqflite.dart';

import '../../../core/storage/meow_database.dart';
import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';

/// Read-only SQLite query tool for LLM introspection.
///
/// Power tool — the LLM should prefer structured tools (agent.list,
/// agent.soul.read, system.config.read) for standard operations and fall
/// back to this only for ad-hoc queries (joins, aggregates, filters)
/// that the structured tools cannot answer.
class SqliteQueryModulePlugin extends ModulePlugin {
  const SqliteQueryModulePlugin();

  @override
  String get moduleId => 'sqlite';

  @override
  String get catalogGroup => 'system';

  @override
  List<String> get capabilityHints => const [
    'sql',
    'query',
    'database',
    'introspect',
    'count',
  ];

  /// Inline schema reference embedded in the tool description so the LLM
  /// can write correct SQL without a separate lookup. Reusable from prompt
  /// builders if needed.
  static const schemaRef = '''
Tables in meow_core.db (read-only):
- app_settings(key TEXT PK, value TEXT)
- agents(id, name, provider_id, model, max_context, auto_compact, icon_key, color_key, created_at, updated_at)
- providers(id, nickname, base_url, api_key_ref, model_default, display_code, codename, models_json, vision_models_json, function_calling_models_json, created_at, updated_at)
  -- api_key_ref is a secure-storage handle, NOT the raw key.
- agent_soul(agent_id PK FK→agents.id, user_name, user_nickname, preferred_language, timezone, work_role, main_project, communication_style, design_preference, persona, persona_meta, updated_at)
- agent_memory(id INTEGER PK, agent_id FK, category, content, created_at)
  -- category: fact|preference|bookmark|session
- agent_events(id INTEGER PK, agent_id FK, event_type, state, task, last_tool, last_result, created_at)
- modules(id TEXT PK, enabled INTEGER, config_json TEXT, installed_at TEXT)
- agent_module_permissions(agent_id FK, module_id FK, enabled INTEGER, config_json TEXT)''';

  @override
  List<ToolDefinition> get toolDefinitions => [
    ToolDefinition(
      name: 'sqlite.query',
      description:
          'Run a read-only SELECT against the local meow_core.db SQLite database. '
          'Power tool for introspection/validation when structured tools cannot answer. '
          'Prefer agent.list, agent.soul.read, system.config.read for normal use; '
          'fall back to this tool only for ad-hoc queries (joins, aggregates, filters). '
          'Rejects anything that is not a SELECT. Capped at 100 rows.\n\n$schemaRef',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
      inputSchema: const {
        'sql':
            'string (required, raw SELECT statement; only SELECT/WITH allowed; results capped at 100 rows)',
      },
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final sql = (request.args['sql'] ?? '').toString().trim();
    if (sql.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'sql is required.',
      );
    }
    final guard = _validateSelectOnly(sql);
    if (guard != null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: guard,
      );
    }

    try {
      final db = await MeowDatabase.instance.database;
      final cappedSql = _applyLimit(sql, 100);
      final rows = await db.rawQuery(cappedSql);
      final truncated = rows.length >= 100;
      return ToolExecutionResult(
        success: true,
        toolName: request.name,
        data: {
          'rowCount': rows.length,
          'truncated': truncated,
          'rows': rows,
        },
      );
    } on DatabaseException catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'SQL error: ${e.toString()}',
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: e.toString(),
      );
    }
  }

  // ─── Security guards ───────────────────────────────────────────────────────

  static String? _validateSelectOnly(String sql) {
    final stripped = _stripComments(sql).trim();
    if (stripped.isEmpty) return 'SQL is empty after stripping comments.';
    // Reject multi-statement.
    final body =
        stripped.endsWith(';') ? stripped.substring(0, stripped.length - 1) : stripped;
    if (body.contains(';')) return 'Only a single SELECT statement is allowed.';
    final upper = body.toUpperCase();
    if (!(upper.startsWith('SELECT') || upper.startsWith('WITH'))) {
      return 'Only SELECT (or WITH...SELECT) is allowed. Got: ${upper.split(RegExp(r"\\s")).first}.';
    }
    // Defense-in-depth: reject any banned keyword anywhere.
    const banned = [
      'INSERT', 'UPDATE', 'DELETE', 'DROP', 'ALTER', 'CREATE',
      'REPLACE', 'TRUNCATE', 'ATTACH', 'DETACH', 'PRAGMA',
      'VACUUM', 'REINDEX', 'BEGIN', 'COMMIT', 'ROLLBACK', 'SAVEPOINT',
    ];
    final tokens = RegExp(r'\b[A-Z]+\b').allMatches(upper).map((m) => m.group(0)!);
    for (final tok in tokens) {
      if (banned.contains(tok)) {
        return 'Banned keyword: $tok. Only SELECT is allowed.';
      }
    }
    return null;
  }

  static String _stripComments(String sql) {
    var s = sql.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ');
    s = s.replaceAll(RegExp(r'--[^\n]*'), ' ');
    return s;
  }

  static String _applyLimit(String sql, int cap) {
    final upper = sql.toUpperCase();
    if (upper.contains(' LIMIT ')) return sql;
    return '$sql LIMIT $cap';
  }
}
