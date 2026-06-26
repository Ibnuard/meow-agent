import '../predefined_skill.dart';

const predefinedWebSkill = PredefinedSkill(
  id: 'meow.web',
  title: 'Web and API Store',
  summary:
      'Fetch HTTPS URLs and list, call, register, or remove APIs from the API Store.',
  toolGroups: ['web'],
  toolNames: [
    'web.fetch',
    'web.api.list',
    'web.api.call',
    'web.api.register',
    'web.api.remove',
  ],
  useWhen: [
    'The user asks to fetch an HTTPS URL or make a one-off HTTP request.',
    'The user wants to list or call APIs saved in the API Store.',
    'The user wants to register or remove a reusable API endpoint.',
  ],
  avoidWhen: [
    'The user wants to open a URL in the Android browser; use meow.app.',
    'The user asks about local workspace files; use meow.files.',
  ],
  requiredContextKeys: ['api_store_registry'],
  examples: [
    '"fetch this API URL" -> web.fetch.',
    '"list my saved APIs" -> web.api.list.',
    '"call @api:name with params" -> web.api.call.',
    '"save this endpoint as an API" -> web.api.register.',
    '"remove this saved API" -> web.api.remove.',
  ],
);
