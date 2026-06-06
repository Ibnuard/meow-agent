import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'device_tools.dart';

class DeviceModulePlugin extends ModulePlugin {
  const DeviceModulePlugin();

  @override
  String get moduleId => 'device_context';

  @override
  String get catalogGroup => 'device';

  @override
  List<String> get capabilityHints => const [
    'device',
    'battery',
    'network',
    'storage',
    'time',
    'locale',
    'foreground app',
    'usage stats',
    'charging',
    'dnd',
    'bluetooth',
    'wifi',
    'cellular',
    'clipboard',
    'copy',
    'paste',
    'copied text',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'device.battery',
      description: 'Read current battery level and charging status.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'device.network',
      description: 'Read current network connection type and status.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'device.storage',
      description: 'Read current device storage usage.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'device.time',
      description: 'Read current local device time and timezone.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'device.locale',
      description: 'Read device language and locale.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'device.summary',
      description:
          'Read a summary of battery, network, storage, time, and locale.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'device.foreground_app',
      description:
          'Read the app that is CURRENTLY in the foreground RIGHT NOW. '
          'This does NOT provide usage history, screen time, or statistics. '
          'If asked about past usage or most-used apps, say you cannot access that data.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'device.usage_stats',
      description:
          'Read real app usage statistics for the past N days (default 7). '
          'Returns top 10 user-facing apps sorted by total usage time in minutes. '
          'Use this when asked about most-used apps, screen time, or app usage history. '
          'Args: days (int, optional, default 7).',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'days': 'int (optional, default 7)'},
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'device.charging',
      description:
          'Read current charging state and plug type (usb, ac, wireless, dock).',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'device.dnd',
      description: 'Read Do Not Disturb status and current mode.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'device.bluetooth',
      description:
          'Read Bluetooth status and connected devices when permission is available.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'device.dnd.set',
      description:
          'Toggle Do Not Disturb on or off. '
          'Args: enabled (bool, required), mode (string, optional: priority_only | alarms_only | total_silence, default priority_only). '
          'Requires notification policy access permission.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'enabled': 'bool (required, true=on false=off)',
        'mode':
            'string (optional: priority_only | alarms_only | total_silence)',
      },
    ),
    ToolDefinition(
      name: 'device.wifi.reconnect',
      description:
          'Reconnect to the last known WiFi network. WiFi must be enabled first.',
      risk: 'sensitive',
      requiresConfirmation: true,
    ),
    ToolDefinition(
      name: 'device.bluetooth.set',
      description:
          'Toggle Bluetooth on or off. Requires Nearby Devices permission on Android 12+. '
          'Args: enabled (bool, required).',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'enabled': 'bool (required, true=on false=off)'},
    ),
    ToolDefinition(
      name: 'device.wifi',
      description:
          'Read detailed WiFi status: enabled, connected, SSID, signal strength, link speed, frequency, IP address.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'device.cellular',
      description:
          'Read cellular/mobile data status: SIM ready, data connected, network type (4G/5G/LTE), operator, roaming.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'clipboard.read',
      description: 'Read current clipboard text.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'clipboard.write',
      description: 'Write text to clipboard.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'text': 'string'},
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) {
    final tools = DeviceTools(moduleRepository: ctx.moduleRepository);
    switch (request.name) {
      case 'device.battery':
        return tools.executeBattery();
      case 'device.network':
        return tools.executeNetwork();
      case 'device.storage':
        return tools.executeStorage();
      case 'device.time':
        return tools.executeTime();
      case 'device.locale':
        return tools.executeLocale();
      case 'device.summary':
        return tools.executeSummary();
      case 'device.foreground_app':
        return tools.executeForegroundApp();
      case 'device.usage_stats':
        return tools.executeUsageStats(request.args);
      case 'device.charging':
        return tools.executeCharging();
      case 'device.dnd':
        return tools.executeDnd();
      case 'device.bluetooth':
        return tools.executeBluetooth();
      case 'device.dnd.set':
        return tools.executeDndSet(request.args);
      case 'device.wifi.reconnect':
        return tools.executeWifiReconnect();
      case 'device.bluetooth.set':
        return tools.executeBluetoothSet(request.args);
      case 'device.wifi':
        return tools.executeWifi();
      case 'device.cellular':
        return tools.executeCellular();
      case 'clipboard.read':
        return tools.executeClipboardRead();
      case 'clipboard.write':
        return tools.executeClipboardWrite(request.args);
      default:
        return Future.value(
          ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'DeviceModulePlugin cannot handle ${request.name}',
          ),
        );
    }
  }
}
