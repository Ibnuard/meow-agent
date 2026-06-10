import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/features/modules/data/module_repository.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';
import 'package:meow_agent/services/agent_runtime/system_tools.dart';
import 'package:meow_agent/services/agent_runtime/tool_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;

  setUpAll(() async {
    docsDir = await Directory.systemTemp.createTemp('meow_system_tools_test_');
    const channel = MethodChannel('com.meowagent.meow_agent/storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getDocumentsPath') return docsDir.path;
          return null;
        });
  });

  tearDownAll(() async {
    if (await docsDir.exists()) {
      await docsDir.delete(recursive: true);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('profile update patches current agent workspace SOUL.md', () async {
    final workspace = Directory('${docsDir.path}/MeowAgent/Agents/Current');
    await workspace.create(recursive: true);
    final soul = File('${workspace.path}/SOUL.md');
    await soul.writeAsString('''# SOUL.md

## Agent Identity

Name: Current

---

## User Identity

Name: [Your Name]
Nickname: [Optional Nickname]
Preferred Language: Indonesian
Timezone: [Your Timezone]

---

## Design Preference

Keep it concise.
''');

    final tools = SystemTools(
      agentId: 'current',
      agentName: 'Current',
      moduleRepository: ModuleRepository(),
    );

    final result = await tools.executeProfileUpdate({
      'field': 'name',
      'value': 'Budi',
    });

    expect(result.success, true);
    final updated = await soul.readAsString();
    expect(updated, contains('## Agent Identity\n\nName: Current'));
    expect(updated, contains('## User Identity\n\nName: Budi'));
    expect(updated, contains('Nickname: [Optional Nickname]'));
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
