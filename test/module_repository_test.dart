import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/features/modules/data/module_model.dart';
import 'package:meow_agent/features/modules/data/module_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ModuleRepository install defaults', () {
    test('install enables module but keeps all settings OFF', () async {
      final repo = ModuleRepository();

      await repo.install(ModuleRegistry.notificationIntelligence);
      final installed = await repo.getInstalled();
      final mod = installed.singleWhere(
        (m) => m.id == 'notification_intelligence',
      );

      expect(mod.enabled, true);
      expect(mod.settings.keys, ModuleRegistry.notificationIntelligence.settings.keys);
      expect(mod.settings.values.every((v) => v == false), true);
    });

    test('migration keeps existing toggles but defaults new keys OFF', () async {
      final prefs = await SharedPreferences.getInstance();
      final legacy = ModuleModel(
        id: 'notification_intelligence',
        name: 'Notification Intelligence',
        description: 'legacy',
        icon: '🔔',
        enabled: true,
        settings: {
          'allow_read': true,
          // New keys missing here should migrate to false.
        },
      );
      await prefs.setStringList('installed_modules', [jsonEncode(legacy.toJson())]);

      final repo = ModuleRepository();
      final installed = await repo.getInstalled();
      final mod = installed.singleWhere(
        (m) => m.id == 'notification_intelligence',
      );

      expect(mod.settings['allow_read'], true);
      expect(mod.settings['allow_summary'], false);
      expect(mod.settings['allow_classify'], false);
      expect(mod.settings['allow_reply_suggestion'], false);
      expect(mod.settings['allow_open_source_app'], false);
      expect(mod.settings['show_logs'], false);
    });
  });
}
