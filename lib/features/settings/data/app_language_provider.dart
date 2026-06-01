import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/local_storage_service.dart';

/// Temporary app language switcher.
/// `system` follows the device locale. For now supported explicit languages:
/// Indonesian and English.
enum AppLanguage { system, id, en }

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
  String get autoCompact =>
      isId ? 'Auto-Compact Konteks' : 'Auto-Compact Context';
  String get autoCompactDesc => isId
      ? 'Ringkas otomatis pesan lama saat batas konteks model hampir tercapai. '
            'Jika dimatikan, agen akan berhenti dan memberi tahu kamu saat konteks penuh.'
      : 'Automatically summarize old messages when the context window approaches '
            'the model limit. When off, the agent stops and asks you how to proceed.';

  String get preferences => isId ? 'PREFERENSI' : 'PREFERENCES';
  String get providers => isId ? 'PROVIDER' : 'PROVIDERS';
  String get developer => isId ? 'PENGEMBANG' : 'DEVELOPER';
  String get support => isId ? 'DUKUNGAN' : 'SUPPORT';
  String get others => isId ? 'LAINNYA' : 'OTHERS';
  String get manageProviders => isId ? 'Kelola Provider' : 'Manage Providers';
  String get darkMode => isId ? 'Mode Gelap' : 'Dark Mode';
  String get language => isId ? 'Bahasa' : 'Language';
  String get languageDescription => isId
      ? 'Pilih bahasa untuk tampilan aplikasi, respons Meow Agent, dan template agen baru.'
      : 'Choose language for the app UI, Meow Agent responses, and new agent templates.';
  String get llmDebugging => isId ? 'Debug LLM (Dev)' : 'LLM Debugging (Dev)';
  String get aboutApp => isId ? 'Tentang Aplikasi' : 'About App';
  String get aboutBody => isId
      ? 'Mobile First Modular Agentic AI.\n\nVersi 0.1.0'
      : 'Mobile First Modular Agentic AI.\n\nVersion 0.1.0';

  String get providerListTitle => isId ? 'Provider' : 'Providers';
  String get addProvider => isId ? 'Tambah Provider' : 'Add Provider';
  String get editProvider => isId ? 'Edit Provider' : 'Edit Provider';
  String get llmProvider => isId ? 'Provider LLM' : 'LLM Provider';
  String get llmProviderDesc => isId
      ? 'Hubungkan endpoint API mana pun yang OpenAI Compatible.'
      : 'Connect any OpenAI Compatible API endpoint.';
  String get providerDetails => isId ? 'Detail Provider' : 'Provider Details';
  String get providerDetailsDesc => isId
      ? 'Berikan nama dan masukkan info koneksi.'
      : 'Give it a name and enter the connection info.';
  String get nickname => isId ? 'Nama Panggilan' : 'Nickname';
  String get nicknameHint => 'e.g. OpenAI, Groq, Local...';
  String get nicknameHelper => isId
      ? 'Ditampilkan di dropdown provider agen.'
      : 'Shown in the agent provider dropdown.';
  String get nicknameRequired =>
      isId ? 'Nama panggilan wajib diisi' : 'Nickname is required';
  String get codename => isId ? 'Kode Provider' : 'Provider Code';
  String get codenameHint =>
      isId ? 'Maks 4 karakter, opsional' : 'Max 4 chars, optional';
  String get codenameHelper => isId
      ? 'Kode pendek akan ditampilkan di header chat.'
      : 'Short code shown in the chat header.';
  String get codenameTooLong =>
      isId ? 'Maksimal 4 karakter' : 'Max 4 characters';
  String get baseUrl => 'Base URL';
  String get baseUrlRequired =>
      isId ? 'Base URL wajib diisi' : 'Base URL is required';
  String get baseUrlInvalid => isId
      ? 'Masukkan URL yang valid (https://...)'
      : 'Enter a valid URL (https://...)';
  String get apiKey => 'API Key';
  String get apiKeyHelper => isId
      ? 'Disimpan dengan aman hanya di perangkat ini.'
      : 'Stored securely on this device only.';
  String get apiKeyRequired =>
      isId ? 'API Key wajib diisi' : 'API Key is required';
  String get model => 'Model';
  String get modelRequired => isId ? 'Model wajib diisi' : 'Model is required';
  String get test => isId ? 'Uji' : 'Test';
  String get testing => isId ? 'Menguji...' : 'Testing...';
  String get saveProvider => isId ? 'Simpan Provider' : 'Save Provider';
  String get deleteProvider => isId ? 'Hapus Provider' : 'Delete Provider';
  String get connectionOk =>
      isId ? 'Koneksi berhasil' : 'Connection successful';
  String get connectionFail => isId ? 'Koneksi gagal' : 'Connection failed';
  String deleteProviderBody(String name) => isId
      ? 'Hapus "$name"?\n\nIni akan menghapus konfigurasi provider dan API key.'
      : 'Delete "$name"?\n\nThis will remove the provider configuration and API key.';
  String affectedAgentsWarning(int count) => isId
      ? '⚠️ $count agen yang menggunakan provider ini akan kehilangan koneksi:'
      : '⚠️ $count agent(s) using this provider will lose their connection:';
  String get noProvidersYet => isId ? 'Belum ada provider' : 'No providers yet';

  // Provider/model missing fallback — used in chat when agent's provider disappeared.
  String get providerMissingTitle =>
      isId ? 'Provider tidak tersedia' : 'Provider unavailable';
  String providerMissingBody(String agentName) => isId
      ? 'Agen "$agentName" memerlukan provider dan model yang valid. '
            'Provider yang terhubung mungkin telah dihapus atau modelnya tidak lagi tersedia. '
            'Silakan atur ulang di halaman Provider.'
      : 'Agent "$agentName" needs a valid provider and model. '
            'The linked provider may have been deleted or its model is no longer available. '
            'Please reconfigure it in the Provider page.';
  String get manageProvidersAction =>
      isId ? 'Atur Provider' : 'Manage Providers';
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
  String get providerNotFound =>
      isId ? 'Provider tidak ditemukan' : 'Provider not found';
  String get pleaseSelectProvider =>
      isId ? 'Silakan pilih provider.' : 'Please select a provider.';

  String get moduleStore => isId ? 'Daftar Modul' : 'Module List';
  String get modules => isId ? 'Modul' : 'Modules';
  String get install => isId ? 'Pasang' : 'Install';
  String get installed => isId ? 'Terpasang' : 'Installed';
  String moduleInstalled(String name) =>
      isId ? '$name terpasang.' : '$name installed.';
  String get active => isId ? 'Aktif' : 'Active';
  String get disabled => isId ? 'Nonaktif' : 'Disabled';
  String get failedLoadModules =>
      isId ? 'Gagal memuat modul.' : 'Failed to load modules.';
  String get noModulesYet => isId ? 'Belum ada modul' : 'No modules yet';
  String get noModulesBrowse => isId
      ? 'Tap "Tambah" untuk melihat modul yang tersedia.'
      : 'Tap "Add" to browse available modules.';
  String get welcomeTitle =>
      isId ? 'Selamat datang di Meow Agent' : 'Welcome to Meow Agent';
  String get welcomeBody => isId
      ? 'Siapkan agen pertamamu untuk mulai. Gunakan API key kompatibel OpenAI milikmu sendiri.'
      : 'Set up your first agent to get started. Bring your own OpenAI-compatible API key.';
  String get setUp => isId ? 'Siapkan' : 'Set Up';
  String get appTagline =>
      isId ? 'AI agentic Android-native' : 'Android-native agentic AI';

  String get permissionRequired =>
      isId ? 'Izin Diperlukan' : 'Permission Required';
  String get openSettings => isId ? 'Buka Pengaturan' : 'Open Settings';
  String get skip => isId ? 'Lewati' : 'Skip';
  String get uninstallModule => isId ? 'Hapus Modul' : 'Uninstall Module';
  String get uninstall => isId ? 'Hapus' : 'Uninstall';
  String get uninstallModuleBody => isId
      ? 'Hapus modul ini dari Meow Agent? Pengaturan modul akan ikut dihapus.'
      : 'Uninstall this module from Meow Agent? Module settings will be removed.';

  String get noActivityYet => isId ? 'Belum ada aktivitas' : 'No activity yet';
  String get activityBody => isId
      ? 'Aksi modul dan proses agen akan muncul di sini.'
      : 'Module actions and agent runs will appear here.';

  String get copyResult => isId ? 'Salin Hasil' : 'Copy Result';
  String get save => isId ? 'Simpan' : 'Save';
  String get copiedToClipboard =>
      isId ? 'Disalin ke clipboard.' : 'Copied to clipboard.';
  String get result => isId ? 'Hasil' : 'Result';
  String get chooseActionAbove => isId
      ? 'Pilih aksi di atas untuk memproses teks.'
      : 'Choose an action above to process the text.';

  String get noAgentConfigured =>
      isId ? 'Belum ada agen dikonfigurasi' : 'No agent configured';
  String get createAgentToChat => isId
      ? 'Buat agen untuk mulai mengobrol.'
      : 'Create an agent to start chatting.';
  String get sayHiToAgent => isId ? 'Sapa agenmu' : 'Say hi to your agent';
  String get askAnythingToStart => isId
      ? 'Tanyakan apa saja untuk memulai.'
      : 'Ask anything to get started.';

  String get newAgent => isId ? 'Agen Baru' : 'New Agent';
  String get newAgentDesc => isId
      ? 'Hubungkan API kompatibel OpenAI sebagai otak agen.'
      : 'Connect an OpenAI-compatible API as your agent brain.';
  String get providerSetupSubtitle => isId
      ? 'Masukkan detail endpoint kompatibel OpenAI.'
      : 'Enter your OpenAI-compatible endpoint details.';
  String get saveAndContinue => isId ? 'Simpan & Lanjut' : 'Save & Continue';
  String get privacyNote => isId
      ? 'API key kamu disimpan secara lokal menggunakan penyimpanan terenkripsi. Tidak pernah keluar dari perangkat kecuali saat memanggil provider pilihanmu.'
      : 'Your API key is stored locally using encrypted storage. It never leaves the device except when calling your chosen provider.';

  String get switchAgent => isId ? 'Ganti Agen' : 'Switch Agent';
  String get typeMessage => isId ? 'Ketik pesan' : 'Type a message';

  // Clipboard processing screen.
  String get clipboard => 'Clipboard';
  String get clipboardCopiedTextLabel =>
      isId ? 'Teks yang Disalin' : 'Copied Text';
  String get clipboardQuickActions => isId ? 'Aksi Cepat' : 'Quick Actions';
  String get clipboardCustomInstruction =>
      isId ? 'Instruksi Kustom' : 'Custom Instruction';
  String get clipboardCustomInstructionHint => isId
      ? 'Contoh: terjemahkan ke bahasa Jepang'
      : 'e.g. translate to Japanese';
  String get clipboardSendCustomPrompt =>
      isId ? 'Kirim instruksi' : 'Send instruction';
  String get clipboardPickAgent => isId ? 'Pilih agen' : 'Choose agent';
  String get clipboardSearchAgent => isId ? 'Cari agen' : 'Search agents';
  String get clipboardAgentNotFound =>
      isId ? 'Agen tidak ditemukan' : 'No agents found';
  String get clipboardNoAgentSelected =>
      isId ? 'Belum ada agen dipilih.' : 'No agent selected.';

  // Clipboard action chips.
  String get clipboardActionSendToChat =>
      isId ? 'Kirim ke Chat' : 'Send to Chat';
  String get clipboardActionTranslate => isId ? 'Terjemahkan' : 'Translate';
  String get clipboardActionSummarize => isId ? 'Ringkas' : 'Summarize';
  String get clipboardActionRewrite => isId ? 'Tulis Ulang' : 'Rewrite';
  String get clipboardActionExplain => isId ? 'Jelaskan' : 'Explain';
  String get clipboardActionGrammar =>
      isId ? 'Perbaiki Tata Bahasa' : 'Fix Grammar';
  String get clipboardActionReply => isId ? 'Susun Balasan' : 'Draft Reply';

  // Chat action strings (moved from inline isId checks)
  String get reply => isId ? 'Balas' : 'Reply';
  String get copyText => isId ? 'Salin teks' : 'Copy text';
  String get cannotReplyEmpty =>
      isId ? 'Tidak bisa membalas pesan kosong.' : 'Cannot reply to an empty message.';

  String modelUpdated(String provider, String model) => isId
      ? 'Model aktif sudah diperbarui.\n\n• Provider: $provider\n• Model: $model'
      : 'Active model updated.\n\n• Provider: $provider\n• Model: $model';

  String get noProviderOrModel => isId
      ? 'Provider atau model untuk agent ini belum tersedia.'
      : 'No provider or models are available for this agent.';

  String chooseModelPrompt(String selected) => isId
      ? 'Pilih model yang ingin dipakai agent ini.\n\nModel aktif sekarang: **$selected**'
      : 'Choose the model this agent should use.\n\nCurrent model: **$selected**';

  String get autoCompactThresholdNote => isId
      ? 'Threshold auto-compact tercapai — pertimbangkan jalankan /compact.'
      : 'Auto-compact threshold reached — consider running /compact.';
  String get autoCompactOkNote => isId
      ? 'Auto-compact aman, belum perlu dijalankan.'
      : 'Auto-compact OK, no action needed.';

  String usageMeasured(String pct, int max, int tokens) => isId
      ? 'Pemakaian aktual (puncak token dari LLM call terakhir): $pct% dari $max max. Histori chat sendiri ~$tokens token.'
      : 'Actual usage (peak tokens from recent LLM calls): $pct% of $max max. Chat history alone is ~$tokens tokens.';

  String usageEstimated(int tokens, String pct, int max) => isId
      ? 'Belum ada panggilan LLM tercatat. Estimasi histori chat: $tokens token ($pct% dari $max max).'
      : 'No LLM call recorded yet. Chat history estimate: $tokens tokens ($pct% of $max max).';
}
