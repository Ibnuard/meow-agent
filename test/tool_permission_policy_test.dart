import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/features/modules/data/module_model.dart';
import 'package:meow_agent/features/modules/data/module_repository.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';
import 'package:meow_agent/services/agent_runtime/tool_permission_policy.dart';
import 'package:meow_agent/services/agent_runtime/tool_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<ModuleRepository> installDeviceContext({
    bool enabled = true,
    bool allowUrls = false,
  }) async {
    final repo = ModuleRepository();
    await repo.install(ModuleRegistry.deviceContext);
    final installed = await repo.getInstalled();
    final module = installed.singleWhere((m) => m.id == 'device_context');
    await repo.update(
      module.copyWith(
        enabled: enabled,
        settings: {...module.settings, 'allow_url_intents': allowUrls},
      ),
    );
    return repo;
  }

  group('Tool permission policy', () {
    test('forceExecute blocks URL intents when toggle is off', () async {
      final repo = await installDeviceContext();
      final router = ToolRouter(moduleRepository: repo);

      final result = await router.forceExecute(
        const ToolCallRequest(
          name: 'intent.open_url',
          args: {'url': 'example.com'},
          risk: 'sensitive',
          requiresConfirmation: false,
        ),
      );

      expect(result.success, false);
      expect(
        result.data?['errorCode'],
        ToolPermissionPolicy.permissionDeniedCode,
      );
      expect(result.data?['settingKey'], 'allow_url_intents');
      expect(result.error, contains('Allow URL Intents'));
    });

    test('execute reaches confirmation gate when URL toggle is on', () async {
      final repo = await installDeviceContext(allowUrls: true);
      final router = ToolRouter(moduleRepository: repo);

      final result = await router.execute(
        const ToolCallRequest(
          name: 'intent.open_url',
          args: {'url': 'example.com'},
          risk: 'sensitive',
          requiresConfirmation: true,
        ),
      );

      expect(result.success, false);
      expect(result.error, 'REQUIRES_CONFIRMATION');
    });

    test('blocks app launch when Device Context module is disabled', () async {
      final repo = await installDeviceContext(enabled: false, allowUrls: true);
      final router = ToolRouter(moduleRepository: repo);

      final result = await router.forceExecute(
        const ToolCallRequest(
          name: 'app.open',
          args: {'package': 'com.example.app'},
          risk: 'sensitive',
          requiresConfirmation: false,
        ),
      );

      expect(result.success, false);
      expect(
        result.data?['errorCode'],
        ToolPermissionPolicy.permissionDeniedCode,
      );
      expect(
        result.data?['reason'],
        ToolPermissionBlockReason.moduleDisabled.name,
      );
    });
  });
}
