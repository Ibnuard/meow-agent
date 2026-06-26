import '../predefined_skill.dart';

const predefinedClipboardSkill = PredefinedSkill(
  id: 'meow.clipboard',
  title: 'Clipboard',
  summary: 'Read and write Android clipboard text.',
  toolGroups: ['clipboard'],
  toolNames: ['clipboard.read', 'clipboard.write'],
  useWhen: [
    'The user asks to read the current clipboard.',
    'The user asks to copy text or place text onto the clipboard.',
  ],
  avoidWhen: [
    'The user wants to save durable memory; use meow.system.',
    'The user wants to write a workspace file; use meow.files.',
  ],
  examples: [
    '"read my clipboard" -> clipboard.read.',
    '"copy this text" -> clipboard.write.',
  ],
);
