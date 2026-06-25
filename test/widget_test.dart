import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:meow_agent/core/storage/app_settings_repository.dart';
import 'package:meow_agent/core/storage/local_storage_service.dart';
import 'package:meow_agent/core/storage/meow_database.dart';
import 'package:meow_agent/main.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('App boots to Home with Set Up CTA when not configured',
      (tester) async {
    final db = MeowDatabase.instance;
    await db.resetForTesting();
    final settingsRepo = AppSettingsRepository(db);
    final storage = LocalStorageService(settingsRepo, {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStorageProvider.overrideWithValue(storage),
        ],
        child: const MeowAgentApp(),
      ),
    );

    // Allow async master-agent loader to settle.
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('MEOW AGENT'), findsOneWidget);
    expect(find.text('Set Up'), findsOneWidget);
  });
}
