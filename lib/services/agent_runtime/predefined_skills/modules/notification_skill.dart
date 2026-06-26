import '../predefined_skill.dart';

const predefinedNotificationSkill = PredefinedSkill(
  id: 'meow.notification',
  title: 'Android notifications',
  summary:
      'Read, summarize, classify, reply to, open, and create Android notifications.',
  toolGroups: ['notification'],
  toolNames: [
    'notification.status',
    'notification.read_recent',
    'notification.summarize',
    'notification.classify',
    'notification.reply_suggestion',
    'notification.open_app',
    'notification.create_local',
    'notification.reply',
  ],
  useWhen: [
    'The user asks about recent Android notifications.',
    'The user wants notification summaries, importance classification, or suggested replies.',
    'The user wants to send a direct reply through an active notification.',
    'The user wants the agent to post a local Android notification.',
  ],
  avoidWhen: [
    'The user wants an internal chat bubble; use meow.chat.',
    'The user wants an external SMS outside notification reply; use meow.communication.',
  ],
  requiredContextKeys: ['notification_access_status', 'recent_notifications'],
  examples: [
    '"do I have notifications?" -> notification.status then notification.read_recent.',
    '"summarize my notifications" -> notification.summarize.',
    '"which notifications are important?" -> notification.classify.',
    '"suggest a reply to that notification" -> notification.reply_suggestion.',
    '"reply to this notification" -> notification.reply.',
    '"notify me with this message" -> notification.create_local.',
  ],
);
