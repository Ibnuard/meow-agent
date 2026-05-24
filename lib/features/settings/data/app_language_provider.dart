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
  String get cancel => isId ? 'Batal' : 'Cancel';
  String get delete => isId ? 'Hapus' : 'Delete';
  String get close => isId ? 'Tutup' : 'Close';
  String get add => isId ? 'Tambah' : 'Add';
  String get saving => isId ? 'Menyimpan...' : 'Saving...';

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
  String get aboutBody => isId
      ? 'AI agentic Android-native.\nModular, sadar permission, dan BYOK.\n\nVersi 0.1.0'
      : 'Android-native agentic AI.\nModular, permission-aware, and BYOK.\n\nVersion 0.1.0';

  String get providerListTitle => isId ? 'Provider' : 'Providers';
  String get addProvider => isId ? 'Tambah Provider' : 'Add Provider';
  String get editProvider => isId ? 'Edit Provider' : 'Edit Provider';
  String get llmProvider => isId ? 'Provider LLM' : 'LLM Provider';
  String get llmProviderDesc => isId
      ? 'Hubungkan endpoint API manapun yang kompatibel dengan OpenAI.'
      : 'Connect any OpenAI-compatible API endpoint.';
  String get providerDetails => isId ? 'Detail Provider' : 'Provider Details';
  String get providerDetailsDesc => isId
      ? 'Berikan nama dan masukkan info koneksi.'
      : 'Give it a name and enter the connection info.';
  String get nickname => isId ? 'Nama Panggilan' : 'Nickname';
  String get nicknameHint => 'e.g. OpenAI, Groq, Local...';
  String get nicknameHelper => isId
      ? 'Ditampilkan di dropdown provider agen.'
      : 'Shown in the agent provider dropdown.';
  String get nicknameRequired => isId ? 'Nama panggilan wajib diisi' : 'Nickname is required';
  String get baseUrl => 'Base URL';
  String get baseUrlRequired => isId ? 'Base URL wajib diisi' : 'Base URL is required';
  String get baseUrlInvalid => isId ? 'Masukkan URL yang valid (https://...)' : 'Enter a valid URL (https://...)';
  String get apiKey => 'API Key';
  String get apiKeyHelper => isId
      ? 'Disimpan dengan aman hanya di perangkat ini.'
      : 'Stored securely on this device only.';
  String get apiKeyRequired => isId ? 'API Key wajib diisi' : 'API Key is required';
  String get model => 'Model';
  String get modelRequired => isId ? 'Model wajib diisi' : 'Model is required';
  String get test => isId ? 'Uji' : 'Test';
  String get testing => isId ? 'Menguji...' : 'Testing...';
  String get saveProvider => isId ? 'Simpan Provider' : 'Save Provider';
  String get deleteProvider => isId ? 'Hapus Provider' : 'Delete Provider';
  String get connectionOk => isId ? 'Koneksi berhasil' : 'Connection successful';
  String get connectionFail => isId ? 'Koneksi gagal' : 'Connection failed';
  String deleteProviderBody(String name) => isId
      ? 'Hapus "$name"?\n\nIni akan menghapus konfigurasi provider dan API key.'
      : 'Delete "$name"?\n\nThis will remove the provider configuration and API key.';
  String affectedAgentsWarning(int count) => isId
      ? '⚠️ $count agen yang menggunakan provider ini akan kehilangan koneksi:'
      : '⚠️ $count agent(s) using this provider will lose their connection:';
  String get noProvidersYet => isId ? 'Belum ada provider' : 'No providers yet';
  String get noProvidersTapAdd => isId
      ? 'Tap + untuk menambahkan provider LLM pertama.'
      : 'Tap + to add your first LLM provider.';
  String get noProvidersTapAddBtn => isId
      ? 'Tap Tambah untuk menghubungkan provider LLM pertama.'
      : 'Tap Add to connect your first LLM provider.';

  String get agentListTitle => isId ? 'Agen' : 'Agents';
  String get addNewAgent => isId ? 'Tambah Agen Baru' : 'Add New Agent';
  String get addAgent => isId ? 'Tambah Agen' : 'Add Agent';
  String get editAgent => isId ? 'Edit Agen' : 'Edit Agent';
  String get setupNewAgent => isId ? 'Buat Agen Baru' : 'Set Up New Agent';
  String get agentWorkspace => isId ? 'Workspace Agen' : 'Agent Workspace';
  String get agentSection => isId ? 'Agen' : 'Agent';
  String get agentSectionDesc => isId
      ? 'Identitas dan konfigurasi agen kamu.'
      : 'Your agent identity and configuration.';
  String get agentName => isId ? 'Nama Agen' : 'Agent Name';
  String get agentNameHint => 'e.g. Assistant, Coder, Researcher...';
  String get nameRequired => isId ? 'Nama wajib diisi' : 'Name is required';
  String get providerSection => 'Provider';
  String get providerSectionDesc => isId
      ? 'Pilih otak AI yang menggerakkan agen ini.'
      : 'Choose which AI brain powers this agent.';
  String get selectProvider => isId ? 'Pilih provider' : 'Select provider';
  String get chooseProvider => isId ? 'Pilih provider' : 'Choose a provider';
  String get saveAgent => isId ? 'Simpan Agen' : 'Save Agent';
  String get deleteAgent => isId ? 'Hapus Agen' : 'Delete Agent';
  String get deleteAgentBody => isId
      ? 'Ini akan menghapus agen ini secara permanen beserta folder workspace dan semua file terkait (SKILLS.md, SOUL.md, HEARTBEAT.md, MEMORY.md).\n\nTindakan ini tidak bisa dibatalkan.'
      : 'This will permanently delete this agent, its workspace folder, and all related files (SKILLS.md, SOUL.md, HEARTBEAT.md, MEMORY.md).\n\nThis action cannot be undone.';
  String get noAgentsYet => isId ? 'Belum ada agen' : 'No agents yet';
  String get noAgentsCreate => isId
      ? 'Buat agen pertamamu untuk mulai mengobrol.'
      : 'Create your first agent to start chatting.';
  String get providerNotFound => isId ? 'Provider tidak ditemukan' : 'Provider not found';
  String get pleaseSelectProvider => isId ? 'Silakan pilih provider.' : 'Please select a provider.';
}
