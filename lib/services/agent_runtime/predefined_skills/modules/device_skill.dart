import '../predefined_skill.dart';

const predefinedDeviceSkill = PredefinedSkill(
  id: 'meow.device',
  title: 'Android device state',
  summary:
      'Read device state and perform sensitive device toggles such as DND, WiFi reconnect, and Bluetooth.',
  toolGroups: ['device'],
  toolNames: [
    'device.battery',
    'device.network',
    'device.storage',
    'device.time',
    'device.locale',
    'device.summary',
    'device.foreground_app',
    'device.usage_stats',
    'device.charging',
    'device.dnd',
    'device.bluetooth',
    'device.dnd.set',
    'device.wifi.reconnect',
    'device.bluetooth.set',
    'device.wifi',
    'device.cellular',
  ],
  useWhen: [
    'The user asks about current Android device state.',
    'The user asks about battery, charging, network, WiFi, cellular, storage, time, locale, foreground app, or usage stats.',
    'The user wants to toggle Do Not Disturb, reconnect WiFi, or toggle Bluetooth.',
  ],
  avoidWhen: [
    'The user wants to open an app or URL; use meow.app.',
    'The user wants clipboard read/write; use meow.clipboard.',
  ],
  requiredContextKeys: ['android_permissions'],
  examples: [
    '"what is my battery?" -> device.battery.',
    '"am I charging?" -> device.charging.',
    '"check my wifi" -> device.wifi.',
    '"what app is open right now?" -> device.foreground_app.',
    '"show my screen time" -> device.usage_stats.',
    '"turn on do not disturb" -> device.dnd.set.',
  ],
);
