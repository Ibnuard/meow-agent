import 'predefined_skill.dart';

/// Compact master index for runtime-v5 skill selection.
///
/// Keep this as a routing map. Full capability details belong in the selected
/// module skill profiles.
const meowAgentMasterSkill = PredefinedSkill(
  id: 'meow.agent.master',
  title: 'Meow Agent skill index',
  summary:
      'Select the smallest set of Meow runtime skills needed for a user request.',
  toolGroups: [
    'app',
    'attachment',
    'calendar',
    'chat',
    'clipboard',
    'communication',
    'system',
    'database',
    'device',
    'files',
    'miniapp',
    'notes',
    'notification',
    'web',
    'workflow',
  ],
  toolNames: [],
  useWhen: [
    'Route an agentic user request to one or more exact runtime skills.',
    'Choose capability context before loading detailed tool examples.',
  ],
  examples: [
    'App launch requests route to meow.app.',
    'Attachment inspection requests route to meow.attachment.',
    'Calendar event requests route to meow.calendar.',
    'Internal chat delivery requests route to meow.chat.',
    'Clipboard requests route to meow.clipboard.',
    'External call, SMS, and contact requests route to meow.communication.',
    'Agent, provider, memory, profile, and capability requests route to meow.system.',
    'Custom table requests route to meow.database.',
    'Android device-state requests route to meow.device.',
    'Workspace document requests route to meow.files.',
    'Mini App builder requests route to meow.miniapp.',
    'Note-taking requests route to meow.notes.',
    'Android notification requests route to meow.notification.',
    'HTTP and API Store requests route to meow.web.',
    'Scheduled automation requests route to meow.workflow.',
  ],
  relatedSkillIds: [
    'meow.app',
    'meow.attachment',
    'meow.calendar',
    'meow.chat',
    'meow.clipboard',
    'meow.communication',
    'meow.system',
    'meow.database',
    'meow.device',
    'meow.files',
    'meow.miniapp',
    'meow.notes',
    'meow.notification',
    'meow.web',
    'meow.workflow',
  ],
);
