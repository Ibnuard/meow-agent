import '../predefined_skill.dart';

const predefinedAppSkill = PredefinedSkill(
  id: 'meow.app',
  title: 'Android app actions',
  summary: 'Open apps, open URLs, list installed apps, and open settings.',
  toolGroups: ['app'],
  toolNames: [
    'app.resolve',
    'app.open',
    'app.list_installed',
    'settings.open',
    'intent.open_url',
  ],
  useWhen: [
    'The user wants to open or launch an Android app.',
    'The user wants to open a web URL through Android intent handling.',
    'The user asks which apps are installed or wants a settings screen opened.',
  ],
  avoidWhen: [
    'The user asks about foreground app, battery, network, or storage state; use meow.device when it exists.',
  ],
  examples: [
    'Open a named app.',
    'Open a URL.',
    'List installed apps.',
    'Open a settings screen.',
  ],
);
