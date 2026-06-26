import '../predefined_skill.dart';

const predefinedNotesSkill = PredefinedSkill(
  id: 'meow.notes',
  title: 'Notes',
  summary:
      'Create, read, search, update, delete, export, pin, archive, and append notes.',
  toolGroups: ['notes'],
  toolNames: [
    'notes.create',
    'notes.list_recent',
    'notes.read',
    'notes.search',
    'notes.update',
    'notes.delete',
    'notes.export',
    'notes.pin',
    'notes.unpin',
    'notes.archive',
    'notes.unarchive',
    'notes.append',
  ],
  useWhen: [
    'The user wants to create or manage markdown notes.',
    'The user asks to search, read, pin, archive, export, or append notes.',
    'The user wants a lightweight durable text record that is not profile memory.',
  ],
  avoidWhen: [
    'The user asks the agent to remember a fact or preference; use meow.system.',
    'The user wants file operations in the workspace; use meow.files.',
  ],
  requiredContextKeys: ['notes_index'],
  examples: [
    'Create a note.',
    'Search notes.',
    'Append to a note.',
    'Archive or pin a note.',
    'Export notes.',
  ],
);
