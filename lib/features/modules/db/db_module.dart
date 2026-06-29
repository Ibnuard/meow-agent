import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'db_tools.dart';

/// Database module plugin: provides sandboxed SQLite storage support.
///
/// Enables agents to dynamically build and query structural databases to power
/// mini apps, keeping the user's data organized and separate from the system registry.
class DatabaseModulePlugin extends ModulePlugin {
  const DatabaseModulePlugin();

  @override
  String get moduleId => 'database';

  @override
  String get catalogGroup => 'database';

  @override
  List<String> get capabilityHints => const [
        'database',
        'sqlite',
        'table',
        'query',
        'sql',
        'insert data',
        'create table',
        'user db',
      ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
        ToolDefinition(
          name: 'db.list_tables',
          description: 'List all user-defined database tables with their row count and columns info.',
          risk: 'safe',
          requiresConfirmation: false,
          inputSchema: {},
          isRetrieval: true,
        ),
        ToolDefinition(
          name: 'db.describe_table',
          description: 'Get schema columns and row count for a specific user database table.',
          risk: 'safe',
          requiresConfirmation: false,
          inputSchema: {
            'table': 'string (required, name of the table to describe)',
          },
          isRetrieval: true,
        ),
        ToolDefinition(
          name: 'db.create_table',
          description:
              'Create a new database table. Schema specifies column names, types (TEXT, INTEGER, REAL, BLOB), nullable and optional default value. Note that a hidden "_id" primary key text column is automatically added.',
          risk: 'sensitive-lite',
          requiresConfirmation: true,
          inputSchema: {
            'table': 'string (required, name of the table to create)',
            'columns': 'list<map> (required, e.g. [{"name": "item", "type": "TEXT", "notNull": true}, {"name": "qty", "type": "INTEGER"}])',
          },
          operation: 'create',
          targetEntity: 'table',
          selectorArgs: ['table'],
          verificationProbe: ToolVerificationProbe(
            kind: 'tool_result_data',
            entityType: 'table',
            expectedDataKeys: ['created', 'table'],
          ),
        ),
        ToolDefinition(
          name: 'db.drop_table',
          description: 'Drop an existing database table. Danger: deletes all data permanently.',
          risk: 'sensitive',
          requiresConfirmation: true,
          inputSchema: {
            'table': 'string (required, name of the table to drop)',
          },
          operation: 'delete',
          targetEntity: 'table',
          selectorArgs: ['table'],
          verificationProbe: ToolVerificationProbe(
            kind: 'tool_result_data',
            entityType: 'table',
            expectedDataKeys: ['dropped', 'table'],
          ),
        ),
        ToolDefinition(
          name: 'db.insert',
          description: 'Insert a new row/record into a database table.',
          risk: 'safe',
          requiresConfirmation: false,
          inputSchema: {
            'table': 'string (required, name of the table)',
            'data': 'map (required, column key-value pairs to insert)',
          },
          operation: 'create',
          targetEntity: 'row',
          selectorArgs: ['table'],
          verificationProbe: ToolVerificationProbe(
            kind: 'tool_result_data',
            entityType: 'row',
            expectedDataKeys: ['inserted', 'id'],
          ),
        ),
        ToolDefinition(
          name: 'db.query',
          description: 'Execute a SELECT statement on the user database. Other commands like INSERT/UPDATE/DELETE are rejected.',
          risk: 'safe',
          requiresConfirmation: false,
          inputSchema: {
            'sql': 'string (required, e.g. "SELECT * FROM expenses WHERE category = ?")',
            'params': 'list (optional, positional arguments for the query placeholders)',
          },
          isRetrieval: true,
        ),
        ToolDefinition(
          name: 'db.update',
          description: 'Update existing rows in a database table matching a where filter.',
          risk: 'sensitive-lite',
          requiresConfirmation: false,
          inputSchema: {
            'table': 'string (required, name of the table)',
            'data': 'map (required, column key-value updates)',
            'where': 'string (required, SQLite where clause, e.g. "_id = ?")',
            'whereArgs': 'list (required, argument values for the where clause placeholders)',
          },
          operation: 'update',
          targetEntity: 'row',
          selectorArgs: ['table'],
          verificationProbe: ToolVerificationProbe(
            kind: 'tool_result_data',
            entityType: 'row',
            expectedDataKeys: ['updated'],
          ),
        ),
        ToolDefinition(
          name: 'db.delete',
          description: 'Delete rows from a database table matching a where filter.',
          risk: 'sensitive-lite',
          requiresConfirmation: true,
          inputSchema: {
            'table': 'string (required, name of the table)',
            'where': 'string (required, SQLite where clause, e.g. "category = ?")',
            'whereArgs': 'list (required, argument values for the where clause placeholders)',
          },
          operation: 'delete',
          targetEntity: 'row',
          selectorArgs: ['table'],
          verificationProbe: ToolVerificationProbe(
            kind: 'tool_result_data',
            entityType: 'row',
            expectedDataKeys: ['deleted'],
          ),
        ),
      ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) {
    final tools = DbTools(moduleRepository: ctx.moduleRepository);
    switch (request.name) {
      case 'db.list_tables':
        return tools.executeListTables(request.args);
      case 'db.describe_table':
        return tools.executeDescribeTable(request.args);
      case 'db.create_table':
        return tools.executeCreateTable(request.args);
      case 'db.drop_table':
        return tools.executeDropTable(request.args);
      case 'db.insert':
        return tools.executeInsert(request.args);
      case 'db.query':
        return tools.executeQuery(request.args);
      case 'db.update':
        return tools.executeUpdate(request.args);
      case 'db.delete':
        return tools.executeDelete(request.args);
      default:
        return Future.value(
          ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'DatabaseModulePlugin cannot handle ${request.name}',
          ),
        );
    }
  }
}
