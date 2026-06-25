import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/core/storage/app_settings_repository.dart';
import 'package:meow_agent/core/storage/legacy_migration.dart';
import 'package:meow_agent/core/storage/meow_database.dart';
import 'package:meow_agent/core/storage/module_entry_repository.dart';
import 'package:meow_agent/features/modules/data/module_model.dart';
import 'package:meow_agent/features/modules/data/module_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await MeowDatabase.instance.resetForTesting();
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

      final db = MeowDatabase.instance;
      await LegacyMigration.runOnce(
        prefs: prefs,
        settings: AppSettingsRepository(db),
        modules: ModuleEntryRepository(db),
      );

      final repo = ModuleRepository();
      final installed = await repo.getInstalled();
      final mod = installed.singleWhere(
        (m) => m.id == 'notification_intelligence',
      );

      expect(mod.settings['allow_read'], true);
      expect(mod.settings['allow_reply'], false);
      expect(mod.settings['persistent_notification'], false);
    });
  });
}
