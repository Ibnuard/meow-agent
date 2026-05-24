import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/local_storage_service.dart';

/// Temporary app language switcher.
/// `system` follows the device locale. For now supported explicit languages:
/// Indonesian and English.
enum AppLanguage {
  system,
  id,
  en,
}

extension AppLanguageX on AppLanguage {
  String get code => switch (this) {
        AppLanguage.system => 'system',
        AppLanguage.id => 'id',
        AppLanguage.en => 'en',
      };

  String get label => switch (this) {
        AppLanguage.system => 'System language',
        AppLanguage.id => 'Bahasa Indonesia',
        AppLanguage.en => 'English',
      };

  static AppLanguage fromCode(String? code) => switch (code) {
        'id' => AppLanguage.id,
        'en' => AppLanguage.en,
        _ => AppLanguage.system,
      };
}

class AppLanguageController extends StateNotifier<AppLanguage> {
  AppLanguageController(this._local)
      : super(AppLanguageX.fromCode(_local.readString(_kLanguageKey)));

  static const _kLanguageKey = 'meow.app.language';

  final LocalStorageService _local;

  Future<void> set(AppLanguage language) async {
    state = language;
    await _local.writeString(_kLanguageKey, language.code);
  }
}

final appLanguageProvider =
    StateNotifierProvider<AppLanguageController, AppLanguage>((ref) {
  return AppLanguageController(ref.watch(localStorageProvider));
});

/// Resolves the effective language from setting + device locale.
String resolveLanguageCode(AppLanguage pref, {Locale? systemLocale}) {
  if (pref == AppLanguage.id) return 'id';
  if (pref == AppLanguage.en) return 'en';

  final locale = systemLocale ?? PlatformDispatcher.instance.locale;
  final lang = locale.languageCode.toLowerCase();
  return lang == 'id' ? 'id' : 'en';
}

String languageLabelFromCode(String code) => switch (code) {
      'id' => 'Indonesian',
      'en' => 'English',
      _ => 'English',
    };

class AppStrings {
  const AppStrings(this.code);

  final String code;

  bool get isId => code == 'id';

  String get settings => isId ? 'Pengaturan' : 'Settings';
  String get home => isId ? 'Beranda' : 'Home';
  String get activity => isId ? 'Aktivitas' : 'Activity';
  String get agent => isId ? 'Agen' : 'Agent';
  String get preferences => isId ? 'PREFERENSI' : 'PREFERENCES';
  String get providers => isId ? 'PROVIDER' : 'PROVIDERS';
  String get developer => isId ? 'PENGEMBANG' : 'DEVELOPER';
  String get support => isId ? 'DUKUNGAN' : 'SUPPORT';
  String get manageProviders => isId ? 'Kelola Provider' : 'Manage Providers';
  String get darkMode => isId ? 'Mode Gelap' : 'Dark Mode';
  String get language => isId ? 'Bahasa' : 'Language';
  String get languageDescription => isId
      ? 'Pilih bahasa untuk tampilan aplikasi, respons Meow Agent, dan template agen baru.'
      : 'Choose language for the app UI, Meow Agent responses, and new agent templates.';
  String get llmDebugging => isId ? 'Debug LLM (Dev)' : 'LLM Debugging (Dev)';
  String get aboutApp => isId ? 'Tentang Aplikasi' : 'About App';
  String get close => isId ? 'Tutup' : 'Close';
  String get aboutBody => isId
      ? 'AI agentic Android-native.\nModular, sadar permission, dan BYOK.\n\nVersi 0.1.0'
      : 'Android-native agentic AI.\nModular, permission-aware, and BYOK.\n\nVersion 0.1.0';
}
