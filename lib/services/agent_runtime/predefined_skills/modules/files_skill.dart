import '../predefined_skill.dart';

const predefinedFilesSkill = PredefinedSkill(
  id: 'meow.files',
  title: 'Workspace files',
  summary: 'Read, write, list, search, move, copy, and delete workspace files.',
  toolGroups: ['files'],
  toolNames: [
    'files.create',
    'files.read',
    'files.write',
    'files.delete',
    'files.list',
    'files.move',
    'files.mkdir',
    'files.copy',
    'files.append',
    'files.metadata',
    'files.search',
    'files.tree',
  ],
  useWhen: [
    'The user asks to inspect or modify files in the MeowAgent workspace.',
    'The user asks to copy or move content between agent workspaces.',
    'The user asks to search, summarize, or organize workspace documents.',
  ],
  avoidWhen: [
    'The user wants durable memory or profile updates; use meow.system.',
    'The user wants custom table records; use meow.database.',
  ],
  requiredContextKeys: ['workspace_root', 'agent_workspace'],
  examples: [
    'Read a workspace file.',
    'Write or append a workspace file.',
    'List files in a folder.',
    'Copy a file between agent workspaces.',
    'Search workspace files.',
  ],
);
