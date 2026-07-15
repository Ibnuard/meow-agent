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
    'The MeowAgent root is Documents/MeowAgent/; the calling agent workspace is Documents/MeowAgent/Agents/{ThisAgent}/.',
    'Peer agent workspace paths are allowed when explicit, using Agents/<PeerName>/<rel> under the MeowAgent root.',
  ],
  avoidWhen: [
    'The user wants durable memory or profile updates; use meow.system.',
    'The user wants custom table records; use meow.database.',
    'Never treat profile, memory, or persona as workspace files.',
  ],
  requiredContextKeys: ['workspace_root', 'agent_workspace'],
  examples: [
    '"read notes.md" -> files.read.',
    '"write this to report.md" -> files.write.',
    '"append this to log.md" -> files.append.',
    '"list files in docs" -> files.list.',
    '"copy this file to another agent workspace" -> files.copy.',
    '"read a peer agent file" -> files.read with path Agents/<PeerName>/<rel>.',
    '"search workspace files for <query>" -> files.search.',
  ],
);
