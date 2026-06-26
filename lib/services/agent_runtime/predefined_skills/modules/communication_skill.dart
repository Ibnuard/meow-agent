import '../predefined_skill.dart';

const predefinedCommunicationSkill = PredefinedSkill(
  id: 'meow.communication',
  title: 'External communication',
  summary:
      'Resolve contacts, list contacts, make phone calls, and send SMS messages.',
  toolGroups: ['communication'],
  toolNames: [
    'communication.resolve_contact',
    'communication.list_contacts',
    'communication.call',
    'communication.send_sms',
  ],
  useWhen: [
    'The user wants to call someone through cellular phone.',
    'The user wants to send an SMS message.',
    'The user asks to look up or resolve a contact from the device address book.',
  ],
  avoidWhen: [
    'The user wants an internal Meow Agent chat message; use meow.chat.',
    'The user wants a reply to an active Android notification; use meow.notification.',
  ],
  requiredContextKeys: [
    'contacts_permission',
    'phone_permission',
    'sms_permission',
  ],
  examples: [
    '"find contact <name>" -> communication.resolve_contact.',
    '"list contacts matching <query>" -> communication.list_contacts.',
    '"call <name>" -> communication.resolve_contact then communication.call.',
    '"send SMS to <name>" -> communication.resolve_contact then communication.send_sms.',
  ],
);
