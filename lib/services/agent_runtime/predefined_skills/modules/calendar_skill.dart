import '../predefined_skill.dart';

const predefinedCalendarSkill = PredefinedSkill(
  id: 'meow.calendar',
  title: 'Calendar events',
  summary:
      'Create, read, update, delete, and inspect calendar events and availability.',
  toolGroups: ['calendar'],
  toolNames: [
    'calendar.create',
    'calendar.today',
    'calendar.list',
    'calendar.read',
    'calendar.update',
    'calendar.delete',
    'calendar.upcoming',
    'calendar.conflicts',
    'calendar.free_slot',
    'calendar.link_note',
  ],
  useWhen: [
    'The user wants to create or manage a one-time calendar event.',
    'The user asks about today, upcoming agenda, conflicts, or free slots.',
    'The user wants to link notes to a calendar event.',
  ],
  avoidWhen: [
    'The user wants recurring automation or scheduled tool execution; use meow.workflow.',
    'The user wants a simple durable reminder note; use meow.notes.',
  ],
  requiredContextKeys: ['calendar_events', 'device_time'],
  examples: [
    '"create a meeting tomorrow at 9" -> calendar.create.',
    '"what is on my calendar today?" -> calendar.today.',
    '"show events next week" -> calendar.list.',
    '"am I free at 2 PM?" -> calendar.conflicts.',
    '"find me a free hour this week" -> calendar.free_slot.',
    '"delete this event" -> calendar.delete.',
  ],
);
