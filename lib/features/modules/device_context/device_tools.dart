import 'package:flutter/services.dart';

import '../../../services/agent_runtime/app_alias_resolver.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import '../data/module_repository.dart';
import 'device_context_repository.dart';
import 'device_context_service.dart';

class DeviceTools {
  DeviceTools({required this.moduleRepository});

  final ModuleRepository moduleRepository;

  DeviceContextRepository _repo() => DeviceContextRepository(
    service: DeviceContextService(),
    moduleRepository: moduleRepository,
  );

  Future<ToolExecutionResult> executeBattery() async {
    try {
      final info = await _repo().getBattery();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.battery',
          error:
              'Device Context module is disabled or battery info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.battery',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.battery',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeNetwork() async {
    try {
      final info = await _repo().getNetwork();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.network',
          error:
              'Device Context module is disabled or network info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.network',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.network',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeStorage() async {
    try {
      final info = await _repo().getStorage();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.storage',
          error:
              'Device Context module is disabled or storage info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.storage',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.storage',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeTime() async {
    try {
      final info = await _repo().getTime();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.time',
          error: 'Device Context module is disabled or time info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.time',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.time',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeLocale() async {
    try {
      final info = await _repo().getLocale();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.locale',
          error:
              'Device Context module is disabled or locale info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.locale',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.locale',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeSummary() async {
    try {
      final result = await _repo().getSummary();
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
      return ToolExecutionResult(
        success: false,
        toolName: 'device.summary',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeForegroundApp() async {
    try {
      final info = await _repo().getForegroundApp();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.foreground_app',
          error:
              'Device Context module is disabled or foreground app detection not allowed.',
        );
      }
      return ToolExecutionResult(
        success: info.available,
        toolName: 'device.foreground_app',
        data: info.toJson(),
        error: info.available
            ? null
            : 'Foreground app unavailable: ${info.reason}',
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.foreground_app',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeUsageStats(
    Map<String, dynamic> args,
  ) async {
    try {
      final days = (args['days'] as num?)?.toInt() ?? 7;
      final result = await _repo().getUsageStats(days: days);
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.usage_stats',
          error:
              'Device Context module is disabled or foreground app permission not granted.',
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
      return ToolExecutionResult(
        success: false,
        toolName: 'device.usage_stats',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeCharging() async {
    try {
      final info = await _repo().getCharging();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.charging',
          error:
              'Device Context module is disabled or charging info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.charging',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.charging',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeDnd() async {
    try {
      final info = await _repo().getDnd();
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
      return ToolExecutionResult(
        success: false,
        toolName: 'device.dnd',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeBluetooth() async {
    try {
      final info = await _repo().getBluetooth();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.bluetooth',
          error:
              'Device Context module is disabled or Bluetooth status not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.bluetooth',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.bluetooth',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeDndSet(Map<String, dynamic> args) async {
    try {
      final enabled = args['enabled'] as bool? ?? false;
      final mode = args['mode'] as String?;
      final result = await _repo().setDnd(enabled: enabled, mode: mode);
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.dnd.set',
          error:
              'Device Context module is disabled or DND control not allowed.',
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
      return ToolExecutionResult(
        success: false,
        toolName: 'device.dnd.set',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeWifiReconnect() async {
    try {
      final result = await _repo().reconnectWifi();
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.wifi.reconnect',
          error:
              'Device Context module is disabled or network control not allowed.',
        );
      }
      final success = result['success'] as bool? ?? false;
      return ToolExecutionResult(
        success: success,
        toolName: 'device.wifi.reconnect',
        data: result,
        error: success ? null : result['error'] as String?,
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.wifi.reconnect',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeBluetoothSet(
    Map<String, dynamic> args,
  ) async {
    try {
      final enabled = args['enabled'] as bool? ?? false;
      final result = await _repo().setBluetoothEnabled(enabled: enabled);
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.bluetooth.set',
          error:
              'Device Context module is disabled or Bluetooth control not allowed.',
        );
      }
      final success = result['success'] as bool? ?? false;
      return ToolExecutionResult(
        success: success,
        toolName: 'device.bluetooth.set',
        data: result,
        error: success ? null : result['error'] as String?,
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.bluetooth.set',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeWifi() async {
    try {
      final result = await _repo().getWifiStatus();
      if (result.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'device.wifi',
          error: result.error,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.wifi',
        data: result.data,
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.wifi',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeCellular() async {
    try {
      final result = await _repo().getCellularStatus();
      if (result.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'device.cellular',
          error: result.error,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.cellular',
        data: result.data,
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.cellular',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeClipboardRead() async {
    final gate = await _checkClipboardSetting('allow_clipboard_read');
    if (gate != null) {
      return ToolExecutionResult(
        success: false,
        toolName: 'clipboard.read',
        error: gate,
      );
    }
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

  Future<ToolExecutionResult> executeClipboardWrite(
    Map<String, dynamic> args,
  ) async {
    final gate = await _checkClipboardSetting('allow_clipboard_write');
    if (gate != null) {
      return ToolExecutionResult(
        success: false,
        toolName: 'clipboard.write',
        error: gate,
      );
    }
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

  /// Returns null if the clipboard setting is allowed, or an error string
  /// describing why it is blocked.
  Future<String?> _checkClipboardSetting(String settingKey) async {
    final modules = await moduleRepository.getInstalled();
    final mod = modules.where((m) => m.id == 'device_context').firstOrNull;
    if (mod == null || !mod.enabled) {
      return 'Device Context module is disabled.';
    }
    if (mod.settings[settingKey] != true) {
      return 'Clipboard access is not enabled in Device Context settings.';
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // App / Intent / Settings tools (formerly AppTools).
  //
  // The native channel name (`com.meowagent/app_control`) is kept for backwards
  // compatibility with the existing Kotlin handler.
  // ---------------------------------------------------------------------------
  static const _appChannel = MethodChannel('com.meowagent/app_control');

  Future<ToolExecutionResult> executeAppResolve(
    Map<String, dynamic> args,
  ) async {
    try {
      final query = (args['query'] as String? ?? args['name'] as String? ?? '')
          .trim();
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
        data: {'query': query, 'matched': true, 'app': result.toJson()},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app.resolve',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeAppOpen(Map<String, dynamic> args) async {
    try {
      var pkg = (args['package'] as String? ?? '').trim();
      final friendlyName =
          (args['name'] as String? ?? args['query'] as String? ?? '').trim();

      if (pkg.isEmpty && friendlyName.isNotEmpty) {
        final result = await AppAliasResolver.resolve(friendlyName);
        if (result != null && result.confidence >= 0.85) {
          pkg = result.packageName;
        } else if (result != null) {
          return ToolExecutionResult(
            success: false,
            toolName: 'app.open',
            data: {'matched': result.toJson(), 'low_confidence': true},
            error:
                'Low confidence match (${result.confidence.toStringAsFixed(2)}) for "$friendlyName". Best guess: ${result.name}. Use app.resolve and ask user to confirm.',
          );
        }
      }

      if (pkg.isEmpty) {
        return ToolExecutionResult(
          success: false,
          toolName: 'app.open',
          error:
              'Could not resolve app. Call app.resolve first to get the package name.',
        );
      }

      final success =
          await _appChannel.invokeMethod<bool>('openApp', {'package': pkg}) ??
          false;
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

  Future<ToolExecutionResult> executeAppListInstalled() async {
    try {
      final raw = await _appChannel.invokeMethod<List>('listInstalledApps');
      final apps =
          raw?.map((e) => Map<String, String>.from(e as Map)).toList() ?? [];
      return ToolExecutionResult(
        success: true,
        toolName: 'app.list_installed',
        data: {'apps': apps, 'count': apps.length},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app.list_installed',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeOpenSettings(
    Map<String, dynamic> args,
  ) async {
    try {
      final action = args['action'] as String? ?? 'android.settings.SETTINGS';
      await _appChannel.invokeMethod<bool>('openSettings', {'action': action});
      return ToolExecutionResult(
        success: true,
        toolName: 'settings.open',
        data: {'action': action},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'settings.open',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeOpenUrl(Map<String, dynamic> args) async {
    try {
      var url = (args['url'] as String? ?? '').trim();
      if (url.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'intent.open_url',
          error: 'Empty URL.',
        );
      }
      final lower = url.toLowerCase();
      if (!lower.startsWith('http://') &&
          !lower.startsWith('https://') &&
          !lower.contains('://')) {
        url = 'https://$url';
      }
      final success =
          await _appChannel.invokeMethod<bool>('openUrl', {'url': url}) ??
          false;
      return ToolExecutionResult(
        success: success,
        toolName: 'intent.open_url',
        data: {'url': url, 'opened': success},
        error: success ? null : 'Failed to open URL: $url',
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'intent.open_url',
        error: e.toString(),
      );
    }
  }
}
