import '../predefined_skill.dart';

const predefinedDatabaseSkill = PredefinedSkill(
  id: 'meow.database',
  title: 'User database',
  summary: 'Create, inspect, query, update, and delete user-defined tables.',
  toolGroups: ['database'],
  toolNames: [
    'db.list_tables',
    'db.describe_table',
    'db.create_table',
    'db.drop_table',
    'db.insert',
    'db.query',
    'db.update',
    'db.delete',
  ],
  useWhen: [
    'The user asks about custom tables or records in the user database.',
    'The user wants a tracker, list, log, schedule, or custom app backend.',
    'The user wants to insert, update, delete, or query rows in user tables.',
    'The user database is meow_user.db and is accessed through db.* tools only.',
    'Use db.list_tables before assuming a custom table exists.',
    'Use db.describe_table before constructing table-specific inserts or updates.',
  ],
  avoidWhen: [
    'The user asks about Meow Agent system tables; use meow.system.',
    'The user asks about files in the workspace; use meow.files.',
    'Never use db.* tools on system tables such as agents, agent_soul, providers, modules, or app_settings.',
  ],
  requiredContextKeys: ['user_database_tables'],
  examples: [
    '"list all my custom database tables" -> db.list_tables.',
    '"what is the schema of table expenses?" -> db.describe_table.',
    '"create database table money_tracker with category and amount" -> db.create_table.',
    '"show all rows in my expenses table" -> db.query.',
    '"add a row of food expense for 5000" -> db.insert.',
    '"delete expense where category is food" -> db.delete.',
  ],
);
