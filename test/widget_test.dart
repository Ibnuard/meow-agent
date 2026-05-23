import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meow_agent/core/storage/local_storage_service.dart';
import 'package:meow_agent/main.dart';

void main() {
  testWidgets('App boots to Home with Set Up CTA when not configured',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
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
