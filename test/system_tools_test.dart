import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/core/storage/agent_soul_repository.dart';
import 'package:meow_agent/core/storage/meow_database.dart';
import 'package:meow_agent/features/modules/data/module_repository.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';
import 'package:meow_agent/services/agent_runtime/system_tools.dart';
import 'package:meow_agent/services/agent_runtime/tool_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    docsDir = await Directory.systemTemp.createTemp('meow_system_tools_test_');
    const channel = MethodChannel('com.meowagent.meow_agent/storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getDocumentsPath') return docsDir.path;
          return null;
        });
  });

  tearDownAll(() async {
    await MeowDatabase.instance.close();
    if (await docsDir.exists()) {
      await docsDir.delete(recursive: true);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('profile update patches agent_soul SQLite table', () async {
    final db = await MeowDatabase.instance.database;
    await MeowDatabase.instance.resetForTesting();

    await db.insert('providers', {
      'id': 'fake_provider',
      'nickname': 'Fake',
      'base_url': 'http://localhost',
      'api_key_ref': 'fake_ref',
      'model_default': 'gpt-4o-mini',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('agents', {
      'id': 'current',
      'name': 'Current',
      'provider_id': 'fake_provider',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('agent_soul', {
      'agent_id': 'current',
      'user_name': '[Your Name]',
      'user_nickname': '[Optional Nickname]',
      'preferred_language': 'Indonesian',
      'timezone': '[Your Timezone]',
      'updated_at': DateTime.now().toIso8601String(),
    });

    final repo = AgentSoulRepository(MeowDatabase.instance);

    final tools = SystemTools(
      agentId: 'current',
      agentName: 'Current',
      moduleRepository: ModuleRepository(),
      coreSoulRepo: repo,
    );

    final result = await tools.executeProfileUpdate({
      'field': 'name',
      'value': 'Budi',
    });

    expect(result.success, true);
    final soul = await repo.get('current');
    expect(soul, isNotNull);
    expect(soul!.userName, 'Budi');
    expect(soul.userNickname, '[Optional Nickname]');
  });

  test('router registers core system tools', () {
    final router = ToolRouter();

    expect(
      router.validate(
        const ToolCallRequest(
          name: 'system.self',
          risk: 'safe',
          requiresConfirmation: false,
        ),
      ),
      isNull,
    );
    expect(router.getDefinition('system.profile.update'), isNotNull);
    expect(router.getDefinition('system.memory.append'), isNotNull);
    expect(router.getDefinition('system.config.read'), isNotNull);
    expect(router.getDefinition('system.config.patch'), isNotNull);
    expect(router.getDefinition('system.agents.create'), isNull);
    expect(router.getDefinition('system.modules.list'), isNull);

    final patchConfig = router.getDefinition('system.config.patch')!;
    expect(patchConfig.operation, 'update');
    expect(patchConfig.targetEntity, 'config');
    expect(patchConfig.requiresConfirmation, true);
  });
}
