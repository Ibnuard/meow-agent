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
}
