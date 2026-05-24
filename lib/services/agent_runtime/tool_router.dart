import 'package:flutter/services.dart';

import '../../features/modules/device_context/device_context_repository.dart';
import '../../features/modules/device_context/device_context_service.dart';
import '../../features/modules/data/module_repository.dart';
import 'app_alias_resolver.dart';
import 'runtime_models.dart';

/// Routes tool calls to their implementations.
/// Validates tool existence and enforces risk/confirmation rules.
class ToolRouter {
  ToolRouter();

  /// Registry of all known tools with their definitions.
  final Map<String, ToolDefinition> _registry = {
    'clipboard.read': const ToolDefinition(
      name: 'clipboard.read',
      description: 'Read current clipboard text.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'clipboard.write': const ToolDefinition(
      name: 'clipboard.write',
      description: 'Write text to clipboard.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'text': 'string'},
    ),
    'app.resolve': const ToolDefinition(
      name: 'app.resolve',
      description: 'Resolve a friendly app name (e.g. "wa", "toko ijo", "youtube") to a package name. ALWAYS call this first before app.open.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'query': 'string (friendly name to resolve)'},
    ),
    'app.open': const ToolDefinition(
      name: 'app.open',
      description: 'Open an installed app by exact package name. Use app.resolve first to get the package name.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'package': 'string (exact package name from app.resolve)'},
    ),
    'app.list_installed': const ToolDefinition(
      name: 'app.list_installed',
      description: 'List all installed launchable apps.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'settings.open': const ToolDefinition(
      name: 'settings.open',
      description: 'Open Android system settings.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'action': 'string'},
    ),
    'intent.open_url': const ToolDefinition(
      name: 'intent.open_url',
      description: 'Open a URL in the default browser.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'url': 'string'},
    ),
    // ── Device Context ──────────────────────────────────────────────────
    'device.battery': const ToolDefinition(
      name: 'device.battery',
      description: 'Read current battery level and charging status.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.network': const ToolDefinition(
      name: 'device.network',
      description: 'Read current network connection type and status.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.storage': const ToolDefinition(
      name: 'device.storage',
      description: 'Read current device storage usage.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.time': const ToolDefinition(
      name: 'device.time',
      description: 'Read current local device time and timezone.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.locale': const ToolDefinition(
      name: 'device.locale',
      description: 'Read device language and locale.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.summary': const ToolDefinition(
      name: 'device.summary',
      description: 'Read a summary of battery, network, storage, time, and locale.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.foreground_app': const ToolDefinition(
      name: 'device.foreground_app',
      description: 'Read the app that is CURRENTLY in the foreground RIGHT NOW. '
          'This does NOT provide usage history, screen time, or statistics. '
          'If asked about past usage or most-used apps, say you cannot access that data.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.usage_stats': const ToolDefinition(
      name: 'device.usage_stats',
      description: 'Read real app usage statistics for the past N days (default 7). '
          'Returns top 10 user-facing apps sorted by total usage time in minutes. '
          'Use this when asked about most-used apps, screen time, or app usage history. '
          'Args: days (int, optional, default 7).',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'days': 'int (optional, default 7)'},
    ),
    'device.charging': const ToolDefinition(
      name: 'device.charging',
      description: 'Read current charging state and plug type (usb, ac, wireless, dock).',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.dnd': const ToolDefinition(
      name: 'device.dnd',
      description: 'Read Do Not Disturb status and current mode.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.bluetooth': const ToolDefinition(
      name: 'device.bluetooth',
      description: 'Read Bluetooth status and connected devices when permission is available.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.dnd.set': const ToolDefinition(
      name: 'device.dnd.set',
      description: 'Toggle Do Not Disturb on or off. '
          'Args: enabled (bool, required), mode (string, optional: priority_only | alarms_only | total_silence, default priority_only). '
          'Requires notification policy access permission.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'enabled': 'bool (required, true=on false=off)',
        'mode': 'string (optional: priority_only | alarms_only | total_silence)',
      },
    ),
  };

  /// Get all registered tool names.
  List<String> get registeredTools => _registry.keys.toList();

  /// Check if a tool is registered.
  bool isRegistered(String name) => _registry.containsKey(name);

  /// Get the authoritative definition for a tool.
  /// Risk level comes from HERE, not from LLM output.
  ToolDefinition? getDefinition(String name) => _registry[name];

  /// Validate a tool call request against the registry.
  /// Returns null if valid, or an error message if invalid.
  String? validate(ToolCallRequest request) {
    if (!isRegistered(request.name)) {
      return 'Unknown tool: ${request.name}. Not registered.';
    }
    return null;
  }

  /// Execute a tool. Returns the result.
  /// IMPORTANT: Does NOT execute if tool requires confirmation.
  Future<ToolExecutionResult> execute(ToolCallRequest request) async {
    final definition = _registry[request.name];
    if (definition == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Tool not found: ${request.name}',
      );
    }

    // Enforce confirmation from registry definition, not LLM.
    if (definition.requiresConfirmation) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'REQUIRES_CONFIRMATION',
      );
    }

    return _dispatch(request);
  }

  /// Force-execute a tool (user already confirmed). Bypasses confirmation.
  Future<ToolExecutionResult> forceExecute(ToolCallRequest request) async {
    final definition = _registry[request.name];
    if (definition == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Tool not found: ${request.name}',
      );
    }
    return _dispatch(request);
  }

  Future<ToolExecutionResult> _dispatch(ToolCallRequest request) async {
    switch (request.name) {
      case 'clipboard.read':
        return _executeClipboardRead();
      case 'clipboard.write':
        return _executeClipboardWrite(request.args);
      case 'app.resolve':
        return _executeAppResolve(request.args);
      case 'app.open':
        return _executeAppOpen(request.args);
      case 'app.list_installed':
        return _executeListInstalledApps();
      case 'settings.open':
        return _executeOpenSettings(request.args);
      case 'intent.open_url':
        return _executeOpenUrl(request.args);
      case 'device.battery':
        return _executeDeviceBattery();
      case 'device.network':
        return _executeDeviceNetwork();
      case 'device.storage':
        return _executeDeviceStorage();
      case 'device.time':
        return _executeDeviceTime();
      case 'device.locale':
        return _executeDeviceLocale();
      case 'device.summary':
        return _executeDeviceSummary();
      case 'device.foreground_app':
        return _executeDeviceForegroundApp();
      case 'device.usage_stats':
        return _executeDeviceUsageStats(request.args);
      case 'device.charging':
        return _executeDeviceCharging();
      case 'device.dnd':
        return _executeDeviceDnd();
      case 'device.bluetooth':
        return _executeDeviceBluetooth();
      case 'device.dnd.set':
        return _executeDeviceDndSet(request.args);
      default:
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'No implementation for tool: ${request.name}',
        );
    }
  }

  Future<ToolExecutionResult> _executeClipboardRead() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      return ToolExecutionResult(
        success: true,
        toolName: 'clipboard.read',
        data: {'text': text},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'clipboard.read',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeClipboardWrite(
      Map<String, dynamic> args) async {
    try {
      final text = args['text'] as String? ?? '';
      await Clipboard.setData(ClipboardData(text: text));
      return ToolExecutionResult(
        success: true,
        toolName: 'clipboard.write',
        data: {'written': true},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'clipboard.write',
        error: e.toString(),
      );
    }
  }

  static const _appChannel = MethodChannel('com.meowagent/app_control');

  Future<ToolExecutionResult> _executeAppResolve(Map<String, dynamic> args) async {
    try {
      final query = (args['query'] as String? ?? args['name'] as String? ?? '').trim();
      if (query.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'app.resolve',
          error: 'Empty query. Provide an app name to resolve.',
        );
      }
      final result = await AppAliasResolver.resolve(query);
      if (result == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'app.resolve',
          data: {'query': query, 'matched': false},
          error: 'No app matched query: "$query"',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'app.resolve',
        data: {
          'query': query,
          'matched': true,
          'app': result.toJson(),
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app.resolve',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeAppOpen(Map<String, dynamic> args) async {
    try {
      // Prefer explicit package; fall back to resolving "name" via resolver.
      var pkg = (args['package'] as String? ?? '').trim();
      final friendlyName = (args['name'] as String? ?? args['query'] as String? ?? '').trim();

      if (pkg.isEmpty && friendlyName.isNotEmpty) {
        final result = await AppAliasResolver.resolve(friendlyName);
        if (result != null && result.confidence >= 0.85) {
          pkg = result.packageName;
        } else if (result != null) {
          // Below high-confidence threshold — surface alternatives.
          return ToolExecutionResult(
            success: false,
            toolName: 'app.open',
            data: {
              'matched': result.toJson(),
              'low_confidence': true,
            },
            error: 'Low confidence match (${result.confidence.toStringAsFixed(2)}) for "$friendlyName". Best guess: ${result.name}. Use app.resolve and ask user to confirm.',
          );
        }
      }

      if (pkg.isEmpty) {
        return ToolExecutionResult(
          success: false,
          toolName: 'app.open',
          error: 'Could not resolve app. Call app.resolve first to get the package name.',
        );
      }

      final success = await _appChannel.invokeMethod<bool>('openApp', {'package': pkg}) ?? false;
      return ToolExecutionResult(
        success: success,
        toolName: 'app.open',
        data: {'package': pkg, 'opened': success},
        error: success ? null : 'App not found or could not be launched: $pkg',
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app.open',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeListInstalledApps() async {
    try {
      final raw = await _appChannel.invokeMethod<List>('listInstalledApps');
      final apps = raw?.map((e) => Map<String, String>.from(e as Map)).toList() ?? [];
      return ToolExecutionResult(
        success: true,
        toolName: 'app.list_installed',
        data: {'apps': apps, 'count': apps.length},
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'app.list_installed', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeOpenSettings(Map<String, dynamic> args) async {
    try {
      final action = args['action'] as String? ?? 'android.settings.SETTINGS';
      await _appChannel.invokeMethod<bool>('openSettings', {'action': action});
      return ToolExecutionResult(
        success: true,
        toolName: 'settings.open',
        data: {'action': action},
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'settings.open', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeOpenUrl(Map<String, dynamic> args) async {
    try {
      var url = (args['url'] as String? ?? '').trim();
      if (url.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'intent.open_url',
          error: 'Empty URL.',
        );
      }
      // Auto-prefix scheme if missing.
      final lower = url.toLowerCase();
      if (!lower.startsWith('http://') &&
          !lower.startsWith('https://') &&
          !lower.contains('://')) {
        url = 'https://$url';
      }
      final success = await _appChannel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
      return ToolExecutionResult(
        success: success,
        toolName: 'intent.open_url',
        data: {'url': url, 'opened': success},
        error: success ? null : 'Failed to open URL: $url',
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'intent.open_url', error: e.toString());
    }
  }

  // ── Device Context helpers ───────────────────────────────────────────

  DeviceContextRepository _deviceRepo() => DeviceContextRepository(
        service: DeviceContextService(),
        moduleRepository: ModuleRepository(),
      );

  Future<ToolExecutionResult> _executeDeviceBattery() async {
    try {
      final repo = _deviceRepo();
      final info = await repo.getBattery();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.battery',
          error: 'Device Context module is disabled or battery info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.battery',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.battery', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceNetwork() async {
    try {
      final info = await _deviceRepo().getNetwork();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.network',
          error: 'Device Context module is disabled or network info not allowed.',
        );
      }
      return ToolExecutionResult(success: true, toolName: 'device.network', data: info.toJson());
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.network', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceStorage() async {
    try {
      final info = await _deviceRepo().getStorage();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.storage',
          error: 'Device Context module is disabled or storage info not allowed.',
        );
      }
      return ToolExecutionResult(success: true, toolName: 'device.storage', data: info.toJson());
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.storage', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceTime() async {
    try {
      final info = await _deviceRepo().getTime();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.time',
          error: 'Device Context module is disabled or time info not allowed.',
        );
      }
      return ToolExecutionResult(success: true, toolName: 'device.time', data: info.toJson());
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.time', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceLocale() async {
    try {
      final info = await _deviceRepo().getLocale();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.locale',
          error: 'Device Context module is disabled or locale info not allowed.',
        );
      }
      return ToolExecutionResult(success: true, toolName: 'device.locale', data: info.toJson());
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.locale', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceSummary() async {
    try {
      final result = await _deviceRepo().getSummary();
      if (result.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'device.summary',
          error: result.error,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.summary',
        data: result.data ?? {},
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.summary', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceForegroundApp() async {
    try {
      final info = await _deviceRepo().getForegroundApp();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.foreground_app',
          error: 'Device Context module is disabled or foreground app detection not allowed.',
        );
      }
      return ToolExecutionResult(
        success: info.available,
        toolName: 'device.foreground_app',
        data: info.toJson(),
        error: info.available ? null : 'Foreground app unavailable: ${info.reason}',
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.foreground_app', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceUsageStats(Map<String, dynamic> args) async {
    try {
      final days = (args['days'] as num?)?.toInt() ?? 7;
      final result = await _deviceRepo().getUsageStats(days: days);
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.usage_stats',
          error: 'Device Context module is disabled or foreground app permission not granted.',
        );
      }
      final available = result['available'] as bool? ?? false;
      if (!available) {
        return ToolExecutionResult(
          success: false,
          toolName: 'device.usage_stats',
          error: 'Usage stats unavailable: ${result['reason'] ?? 'unknown'}',
          data: result,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.usage_stats',
        data: result,
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.usage_stats', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceCharging() async {
    try {
      final info = await _deviceRepo().getCharging();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.charging',
          error: 'Device Context module is disabled or charging info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.charging',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.charging', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceDnd() async {
    try {
      final info = await _deviceRepo().getDnd();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.dnd',
          error: 'Device Context module is disabled or DND status not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.dnd',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.dnd', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceBluetooth() async {
    try {
      final info = await _deviceRepo().getBluetooth();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.bluetooth',
          error: 'Device Context module is disabled or Bluetooth status not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.bluetooth',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.bluetooth', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceDndSet(Map<String, dynamic> args) async {
    try {
      final enabled = args['enabled'] as bool? ?? false;
      final mode = args['mode'] as String?;
      final result = await _deviceRepo().setDnd(enabled: enabled, mode: mode);
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.dnd.set',
          error: 'Device Context module is disabled or DND control not allowed.',
        );
      }
      final success = result['success'] as bool? ?? false;
      if (!success) {
        return ToolExecutionResult(
          success: false,
          toolName: 'device.dnd.set',
          error: result['error'] as String? ?? 'Failed to set DND mode.',
          data: result,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.dnd.set',
        data: result,
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.dnd.set', error: e.toString());
    }
  }
}
