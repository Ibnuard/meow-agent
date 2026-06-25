import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/features/modules/data/module_model.dart';
import 'package:meow_agent/features/modules/data/module_repository.dart';
import 'package:meow_agent/features/modules/device_context/device_context_models.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';
import 'package:meow_agent/services/agent_runtime/tool_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  group('device.charging', () {
    test('success — parses charging info correctly', () {
      final raw = {
        'isCharging': true,
        'status': 'charging',
        'pluggedType': 'usb',
        'level': 87,
      };

      final info = ChargingInfo.fromMap(raw);

      expect(info.isCharging, true);
      expect(info.status, 'charging');
      expect(info.pluggedType, 'usb');
      expect(info.level, 87);
    });

    test('toJson round-trip preserves all fields', () {
      const info = ChargingInfo(
        isCharging: false,
        status: 'discharging',
        pluggedType: 'none',
        level: 42,
      );

      final json = info.toJson();

      expect(json['isCharging'], false);
      expect(json['status'], 'discharging');
      expect(json['pluggedType'], 'none');
      expect(json['level'], 42);
    });

    test('fromMap handles null/missing fields gracefully', () {
      final info = ChargingInfo.fromMap({});

      expect(info.isCharging, false);
      expect(info.status, 'unknown');
      expect(info.pluggedType, 'unknown');
      expect(info.level, 0);
    });

    test('tool is registered as safe with no confirmation', () {
      final router = ToolRouter();
      final def = router.getDefinition('device.charging');

      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
    });
  });

  group('device.dnd', () {
    test('parses DND info correctly', () {
      final raw = {
        'enabled': true,
        'mode': 'priority_only',
        'hasPolicyAccess': true,
      };

      final info = DndInfo.fromMap(raw);

      expect(info.enabled, true);
      expect(info.mode, 'priority_only');
      expect(info.hasPolicyAccess, true);
    });

    test('unavailable returns unknown mode cleanly', () {
      // Simulates when NotificationManager is unavailable or policy access missing.
      final raw = {
        'enabled': false,
        'mode': 'unknown',
        'hasPolicyAccess': false,
      };

      final info = DndInfo.fromMap(raw);

      expect(info.enabled, false);
      expect(info.mode, 'unknown');
      expect(info.hasPolicyAccess, false);
    });

    test('fromMap handles null/missing fields gracefully', () {
      final info = DndInfo.fromMap({});

      expect(info.enabled, false);
      expect(info.mode, 'unknown');
      expect(info.hasPolicyAccess, false);
    });

    test('tool is registered as safe with no confirmation', () {
      final router = ToolRouter();
      final def = router.getDefinition('device.dnd');

      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
    });
  });

  group('device.bluetooth', () {
    test('parses bluetooth info with connected devices', () {
      final raw = {
        'enabled': true,
        'permissionGranted': true,
        'connectedDevices': [
          {'name': 'AirPods', 'address': null, 'type': 'audio'},
          {'name': 'Speaker', 'address': null, 'type': 'audio'},
        ],
      };

      final info = BluetoothInfo.fromMap(raw);

      expect(info.enabled, true);
      expect(info.permissionGranted, true);
      expect(info.connectedDevices.length, 2);
      expect(info.connectedDevices[0].name, 'AirPods');
      expect(info.connectedDevices[0].type, 'audio');
      expect(info.connectedDevices[1].name, 'Speaker');
    });

    test('permission missing does not crash — returns safe fallback', () {
      // Simulates Android 12+ without BLUETOOTH_CONNECT permission.
      final raw = {
        'enabled': null,
        'permissionGranted': false,
        'connectedDevices': <Map<String, dynamic>>[],
      };

      final info = BluetoothInfo.fromMap(raw);

      expect(info.enabled, isNull);
      expect(info.permissionGranted, false);
      expect(info.connectedDevices, isEmpty);
    });

    test('fromMap handles completely empty map gracefully', () {
      final info = BluetoothInfo.fromMap({});

      expect(info.enabled, isNull);
      expect(info.permissionGranted, false);
      expect(info.connectedDevices, isEmpty);
    });

    test('toJson includes null enabled when permission missing', () {
      const info = BluetoothInfo(
        enabled: null,
        permissionGranted: false,
        connectedDevices: [],
      );

      final json = info.toJson();

      expect(json['enabled'], isNull);
      expect(json['permissionGranted'], false);
      expect(json['connectedDevices'], isEmpty);
    });

    test('tool is registered as safe with no confirmation', () {
      final router = ToolRouter();
      final def = router.getDefinition('device.bluetooth');

      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
    });
  });

  group('device.summary includes new tools', () {
    test('tool is registered', () {
      final router = ToolRouter();
      final def = router.getDefinition('device.summary');

      expect(def, isNotNull);
      expect(def!.risk, 'safe');
    });

    test('all new tools are registered in ToolRouter', () {
      final router = ToolRouter();
      final tools = router.registeredTools;

      expect(tools, contains('device.charging'));
      expect(tools, contains('device.dnd'));
      expect(tools, contains('device.bluetooth'));
      expect(tools, contains('device.summary'));
    });
  });

  group('BluetoothDeviceInfo', () {
    test('fromMap parses device correctly', () {
      final raw = {'name': 'Galaxy Buds', 'address': null, 'type': 'audio'};
      final device = BluetoothDeviceInfo.fromMap(raw);

      expect(device.name, 'Galaxy Buds');
      expect(device.address, isNull);
      expect(device.type, 'audio');
    });

    test('fromMap defaults to Unknown name and other type', () {
      final device = BluetoothDeviceInfo.fromMap({});

      expect(device.name, 'Unknown');
      expect(device.type, 'other');
    });
  });

  group('device.dnd.set', () {
    test('tool is registered as sensitive with confirmation', () {
      final router = ToolRouter();
      final def = router.getDefinition('device.dnd.set');

      expect(def, isNotNull);
      expect(def!.risk, 'sensitive');
      expect(def.requiresConfirmation, true);
    });

    test('tool has correct input schema', () {
      final router = ToolRouter();
      final def = router.getDefinition('device.dnd.set')!;

      expect(def.inputSchema.containsKey('enabled'), true);
      expect(def.inputSchema.containsKey('mode'), true);
    });

    test(
      'execute returns REQUIRES_CONFIRMATION without forceExecute',
      () async {
        SharedPreferences.setMockInitialValues({});
        final repo = ModuleRepository();
        await repo.install(ModuleRegistry.deviceContext);
        final installed = await repo.getInstalled();
        final module = installed.singleWhere((m) => m.id == 'device_context');
        await repo.update(
          module.copyWith(settings: {...module.settings, 'allow_dnd': true}),
        );
        final router = ToolRouter(moduleRepository: repo);
        final request = ToolCallRequest(
          name: 'device.dnd.set',
          args: {'enabled': true, 'mode': 'priority_only'},
          risk: 'sensitive',
          requiresConfirmation: true,
        );

        final result = await router.execute(request);

        expect(result.success, false);
        expect(result.error, 'REQUIRES_CONFIRMATION');
      },
    );
  });
}
