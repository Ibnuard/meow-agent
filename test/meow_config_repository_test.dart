import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/core/storage/meow_config_repository.dart';
import 'package:meow_agent/features/agents/data/agent_model.dart';
import 'package:meow_agent/features/providers/data/provider_config.dart';

void main() {
  test('missing file generates default meow.json', () async {
    final dir = await Directory.systemTemp.createTemp('meow_config_test_');
    addTearDown(() => dir.delete(recursive: true));
    final repo = MeowConfigRepository(root: dir);

    final config = await repo.ensureLoaded();

    expect(config['schemaVersion'], 1);
    expect(await File('${dir.path}/meow.json').exists(), true);
  });

  test('invalid meow.json restores latest valid backup', () async {
    final dir = await Directory.systemTemp.createTemp('meow_config_test_');
    addTearDown(() => dir.delete(recursive: true));
    await Directory('${dir.path}/meow.backups').create();
    await File('${dir.path}/meow.json').writeAsString('{bad');
    await File('${dir.path}/meow.backups/meow-999.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'activeAgentId': null,
        'activeProviderId': null,
        'prefs': {'language': 'system', 'theme': 'dark'},
        'providers': [],
        'agents': [],
        'modules': {},
      }),
    );

    final config = await MeowConfigRepository(root: dir).ensureLoaded();

    expect(config['schemaVersion'], 1);
    expect(
      jsonDecode(await File('${dir.path}/meow.json').readAsString()),
      config,
    );
  });

  test('patch creates backup and rejects provider plaintext apiKey', () async {
    final dir = await Directory.systemTemp.createTemp('meow_config_test_');
    addTearDown(() => dir.delete(recursive: true));
    final repo = MeowConfigRepository(root: dir);
    await repo.ensureLoaded();

    await expectLater(
      repo.patch([
        {
          'op': 'add',
          'path': '/providers/-',
          'value': {
            'id': 'p1',
            'nickname': 'Provider',
            'baseUrl': 'https://example.test/v1',
            'model': 'model',
            'models': ['model'],
            'apiKey': 'secret',
          },
        },
      ]),
      throwsA(isA<MeowConfigException>()),
    );
    expect(await Directory('${dir.path}/meow.backups').exists(), true);
  });

  test(
    'imports legacy prefs into empty config without plaintext secrets',
    () async {
      final dir = await Directory.systemTemp.createTemp('meow_config_test_');
      addTearDown(() => dir.delete(recursive: true));
      final repo = MeowConfigRepository(root: dir);
      await repo.ensureLoaded();

      await repo.importLegacyIfEmpty(
        agentsJson: jsonEncode([
          {'id': 'a1', 'name': 'Agent', 'providerId': 'p1'},
        ]),
        providersJson: jsonEncode([
          {
            'id': 'p1',
            'nickname': 'Provider',
            'baseUrl': 'https://example.test/v1',
            'model': 'model',
            'models': ['model'],
            'apiKey': 'secret',
          },
        ]),
        language: 'id',
        theme: 'light',
        modulesJson: [
          jsonEncode({
            'id': 'notes',
            'name': 'Notes',
            'description': 'Notes',
            'icon': 'notes',
            'enabled': true,
            'settings': {'allow_create': true},
          }),
        ],
      );

      final config = await repo.read();
      expect((config['agents'] as List).single['name'], 'Agent');
      expect((config['providers'] as List).single['apiKey'], isNull);
      expect((config['providers'] as List).single['apiKeyRef'], 'secure://p1');
      expect((config['prefs'] as Map)['language'], 'id');
      expect((config['prefs'] as Map)['theme'], 'light');
      expect(config['activeAgentId'], 'a1');
      expect(config['activeProviderId'], 'p1');
      expect((config['modules'] as Map).containsKey('notes'), true);
    },
  );

  test('agent and provider helpers write config-backed state', () async {
    final dir = await Directory.systemTemp.createTemp('meow_config_test_');
    addTearDown(() => dir.delete(recursive: true));
    final repo = MeowConfigRepository(root: dir);
    await repo.ensureLoaded();

    final provider = ProviderConfig(
      id: 'p1',
      nickname: 'Provider',
      baseUrl: 'https://example.test/v1',
      apiKey: 'secret',
      model: 'model',
    );
    await repo.saveProvider(provider);
    await repo.saveAgent(AgentModel(id: 'a1', name: 'Agent', providerId: 'p1'));

    expect(repo.loadAgents().single.name, 'Agent');
    final config = await repo.read();
    expect((config['providers'] as List).single['apiKey'], isNull);
    expect((config['providers'] as List).single['apiKeyRef'], 'secure://p1');
  });
}
