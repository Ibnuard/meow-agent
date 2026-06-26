import '../predefined_skill.dart';

const predefinedChatSkill = PredefinedSkill(
  id: 'meow.chat',
  title: 'Internal chat delivery',
  summary:
      'Deliver markdown content into the Meow Agent internal chat UI as a chat bubble.',
  toolGroups: ['chat'],
  toolNames: ['chat.send'],
  useWhen: [
    'The user explicitly asks to send or deliver a result into the Meow Agent chat UI.',
    'A workflow needs to post a digest, report, or markdown result as an assistant message.',
  ],
  avoidWhen: [
    'The user wants to send an external SMS or make a phone call; use meow.communication.',
    'The user wants to reply to an Android notification; use meow.notification.',
  ],
  requiredContextKeys: ['current_agent_id'],
  examples: [
    'Send a markdown report to this chat.',
    'Deliver workflow output as a chat bubble.',
  ],
);
