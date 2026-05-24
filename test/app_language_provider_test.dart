import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/features/settings/data/app_language_provider.dart';

void main() {
  group('app language resolution', () {
    test('explicit Indonesian overrides system locale', () {
      final code = resolveLanguageCode(
        AppLanguage.id,
        systemLocale: const Locale('en', 'US'),
      );
      expect(code, 'id');
      expect(languageLabelFromCode(code), 'Indonesian');
    });

    test('explicit English overrides system locale', () {
      final code = resolveLanguageCode(
        AppLanguage.en,
        systemLocale: const Locale('id', 'ID'),
      );
      expect(code, 'en');
      expect(languageLabelFromCode(code), 'English');
    });

    test('system resolves Indonesian device locale to id', () {
      final code = resolveLanguageCode(
        AppLanguage.system,
        systemLocale: const Locale('id', 'ID'),
      );
      expect(code, 'id');
    });

    test('system resolves non-Indonesian locale to English fallback', () {
      final code = resolveLanguageCode(
        AppLanguage.system,
        systemLocale: const Locale('ja', 'JP'),
      );
      expect(code, 'en');
    });

    test('unknown label falls back to English', () {
      expect(languageLabelFromCode('xx'), 'English');
    });
  });
}
