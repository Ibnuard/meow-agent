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
  ],
  avoidWhen: [
    'The user asks about Meow Agent system tables; use meow.system.',
    'The user asks about files in the workspace; use meow.files.',
  ],
  requiredContextKeys: ['user_database_tables'],
  examples: [
    'List user tables.',
    'Describe a user table.',
    'Create a custom table.',
    'Query records from a user table.',
    'Insert or update a row.',
  ],
);
