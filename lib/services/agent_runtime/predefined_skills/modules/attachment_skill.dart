import '../predefined_skill.dart';

const predefinedAttachmentSkill = PredefinedSkill(
  id: 'meow.attachment',
  title: 'Message attachments',
  summary:
      'List attached files, read text attachments, and inspect attached images.',
  toolGroups: ['attachment'],
  toolNames: [
    'attachment.list',
    'attachment.read_text',
    'attachment.describe_image',
  ],
  useWhen: [
    'The current user message includes attached files and asks to inspect them.',
    'The user asks to summarize, transform, or answer from an attached document.',
    'The user asks a visual question about an attached image.',
  ],
  avoidWhen: [
    'The user asks about workspace files rather than current-message attachments; use meow.files.',
  ],
  requiredContextKeys: ['current_message_attachments', 'model_vision_support'],
  examples: [
    '"what files did I attach?" -> attachment.list.',
    '"summarize this attached text file" -> attachment.read_text.',
    '"what is in this image?" -> attachment.describe_image with the user question as prompt.',
    '"answer from the attachment" -> attachment.list then read the relevant supported attachment.',
  ],
);
