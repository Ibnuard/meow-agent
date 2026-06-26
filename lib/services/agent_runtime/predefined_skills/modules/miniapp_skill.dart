import '../predefined_skill.dart';

const predefinedMiniAppSkill = PredefinedSkill(
  id: 'meow.miniapp',
  title: 'Local Mini Apps',
  summary: 'List, create, read, patch, and delete custom local Mini Apps.',
  toolGroups: ['miniapp'],
  toolNames: [
    'miniapp.list',
    'miniapp.create',
    'miniapp.read',
    'miniapp.patch',
    'miniapp.delete',
  ],
  useWhen: [
    'The user wants to create a custom local app or tracker UI.',
    'The user asks to inspect, edit, redesign, patch, or delete an existing Mini App.',
    'The user wants a durable interactive mini app backed by the user database.',
  ],
  avoidWhen: [
    'The user only wants a data table with no custom UI; use meow.database.',
    'The user wants a workspace document; use meow.files.',
  ],
  requiredContextKeys: ['miniapp_registry', 'host_theme_tokens'],
  examples: [
    'List installed Mini Apps.',
    'Create a tracker Mini App.',
    'Read a Mini App definition.',
    'Patch an existing Mini App.',
    'Delete a Mini App.',
  ],
  relatedSkillIds: ['meow.database'],
);
