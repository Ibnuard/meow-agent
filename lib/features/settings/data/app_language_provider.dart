import 'dart:async';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_settings_repository.dart';

/// Storage key for app language in app_settings table.
const _languageKey = 'prefs.language';

/// Initial app language code loaded once at app boot in main() and injected
/// into the [ProviderScope]. Lets [AppLanguageController] start synchronously
/// without blocking the first frame on a SQLite read.
final initialAppLanguageProvider = Provider<String>((_) => 'system');

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

/// Persists the user's language preference.
///
/// Subscribes to [AppSettingsRepository.watchAll] so writes from any path
/// (LLM tools via `system.config.patch /prefs/language`, background tasks)
/// reach the UI immediately.
class AppLanguageController extends StateNotifier<AppLanguage> {
  AppLanguageController(this._settings, String initial)
    : super(AppLanguageX.fromCode(initial)) {
    _sub = _settings.watchAll().listen((map) {
      final fresh = AppLanguageX.fromCode(map[_languageKey]);
      if (mounted && fresh != state) state = fresh;
    });
  }

  final AppSettingsRepository _settings;
  StreamSubscription<Map<String, String>>? _sub;

  Future<void> set(AppLanguage language) async {
    state = language;
    await _settings.set(_languageKey, language.code);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final appLanguageProvider =
    StateNotifierProvider<AppLanguageController, AppLanguage>((ref) {
      return AppLanguageController(
        ref.watch(appSettingsRepositoryProvider),
        ref.watch(initialAppLanguageProvider),
      );
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
      ? 'AI companion Android-native dengan multi-agent, app automation, workflow otomatis, notifikasi cerdas, dan modular tools.\n\nVersi 1.0.0'
      : 'Android-native AI companion with multi-agent, app automation, automated workflows, smart notifications, and modular tools.\n\nVersion 1.0.0';
  String get notificationSound =>
      isId ? 'Suara Notifikasi' : 'Notification Sound';
  String get notificationSoundDesc => isId
      ? 'Pilih suara untuk notifikasi push'
      : 'Choose sound for push notifications';
  String get soundNotification => isId ? 'Notification' : 'Notification';
  String get soundCat => isId ? 'Cat' : 'Cat';
  String get soundPreview => isId ? 'Pratinjau' : 'Preview';
  String get storagePermissionTitle =>
      isId ? 'Izin Penyimpanan Diperlukan' : 'Storage Permission Required';
  String get storagePermissionBody => isId
      ? 'Meow Agent memerlukan akses penyimpanan untuk membaca dan menulis file workspace agen. Tanpa izin ini, chat tidak bisa digunakan.'
      : 'Meow Agent needs storage access to read and write agent workspace files. Without this permission, chat cannot function.';
  String get storagePermissionGrant => isId ? 'Izinkan Akses' : 'Grant Access';
  String get storagePermissionOpenSettings =>
      isId ? 'Buka Pengaturan' : 'Open Settings';

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
  String get modelListLabel => isId ? 'Model Tersedia' : 'Available Models';
  String get modelListHint => 'gpt-4o-mini';
  String get modelListRequired =>
      isId ? 'Model wajib diisi' : 'Model is required';
  String get modelListHelper =>
      isId ? 'Tambahkan model satu per satu.' : 'Add models one by one.';
  String modelTestValid(String model) =>
      isId ? 'Model "$model" tersedia ✓' : 'Model "$model" is available ✓';
  String modelTestInvalid(String model) => isId
      ? 'Model "$model" tidak ditemukan atau tidak dapat diakses'
      : 'Model "$model" not found or not accessible';

  // --- Agent manager ---
  String providerModelsCount(int count) =>
      isId ? '$count model' : '$count models';
  String get chooseModel => isId ? 'Pilih model' : 'Choose model';
  String get advanced => isId ? 'Lanjutan' : 'Advanced';
  String advancedSubtitle(String tokens, bool autoCompact) => isId
      ? 'Konteks $tokens token, auto-compact ${autoCompact ? 'aktif' : 'mati'}'
      : '$tokens token context, auto-compact ${autoCompact ? 'on' : 'off'}';
  String get maxContextLength =>
      isId ? 'Konteks Maksimum' : 'Max Context Length';
  String get tokenLimitHint =>
      isId ? 'Batas token untuk model ini.' : 'Token limit for this model.';
  String get minTokens => isId ? 'Minimal 512 tokens' : 'Minimum 512 tokens';
  String get autoCompactContext =>
      isId ? 'Auto-Compact Konteks' : 'Auto-Compact Context';
  String get autoCompactContextDesc => isId
      ? 'Ringkas pesan lama saat konteks hampir penuh.'
      : 'Summarize older messages near the limit.';
  String get personalizeAgent =>
      isId ? 'Personalisasi Agent' : 'Personalize Agent';
  String get chooseIconAndColor =>
      isId ? 'Pilih ikon dan warna' : 'Choose icon and color';
  String get iconLabel => isId ? 'Ikon' : 'Icon';
  String get colorLabel => isId ? 'Warna' : 'Color';

  // --- Workflow editor ---
  String get workflowSelectAgentFirst =>
      isId ? 'Pilih agent terlebih dahulu.' : 'Please select an agent.';
  String get workflowDeleteTitle =>
      isId ? 'Hapus Workflow?' : 'Delete Workflow?';
  String workflowDeleteMessage(String title) => isId
      ? 'Hapus "$title"?\n\nLangkah dan pengaturan workflow akan dihapus permanen.'
      : 'Delete "$title"?\n\nWorkflow steps and settings will be permanently removed.';
  String get workflowDelete => isId ? 'Hapus' : 'Delete';
  String get workflowCancel => isId ? 'Batal' : 'Cancel';
  String get workflowEditTitle => isId ? 'Edit Workflow' : 'Edit Workflow';
  String get workflowNewTitle => isId ? 'Buat Workflow' : 'New Workflow';
  String get workflowDeleteTooltip => isId ? 'Hapus' : 'Delete';
  String get workflowSectionAgent => isId ? 'Agent' : 'Agent';
  String get workflowSectionTitle => isId ? 'Judul' : 'Title';
  String get workflowSectionTrigger => isId ? 'Trigger' : 'Trigger';
  String get workflowSectionMode => isId ? 'Mode' : 'Mode';
  String get workflowTitleHint => isId ? 'Nama workflow' : 'Workflow name';
  String get workflowSinglePrompt => isId ? 'Single Prompt' : 'Single Prompt';
  String workflowStepsCount(int count) =>
      isId ? '$count langkah' : '$count steps';
  String get workflowAddStep => isId ? 'Tambah Langkah' : 'Add Step';
  String get workflowSendToChat =>
      isId ? 'Kirim hasil ke chat' : 'Send result to chat';
  String get workflowAllowSensitive =>
      isId ? 'Izinkan Aksi Sensitif' : 'Allow Sensitive Actions';
  String get workflowSave => isId ? 'Simpan' : 'Save';
  String get workflowCreate => isId ? 'Buat Workflow' : 'Create';
  String get workflowMoreSettings =>
      isId ? 'Pengaturan Lainnya' : 'More settings';
  String get workflowNotification => isId ? 'Notifikasi' : 'Notification';
  String get workflowPriority => isId ? 'Prioritas' : 'Priority';
  String get workflowTimeout => isId ? 'Timeout' : 'Timeout';
  String get workflowMultiAgent =>
      isId ? 'Mode multi-agent' : 'Multi-agent mode';
  String workflowStepLabel(int i) =>
      isId ? 'Langkah ${i + 1}' : 'Step ${i + 1}';
  String get workflowOnFailure => isId ? 'Jika gagal:' : 'On failure:';
  String get workflowFailureStop => isId ? 'Hentikan' : 'Stop';
  String get workflowFailureSkip => isId ? 'Lewati' : 'Skip';
  String get workflowFailureRetry => isId ? 'Coba lagi' : 'Retry';
  String get workflowChooseStepAgent =>
      isId ? 'Pilih agent langkah' : 'Choose step agent';
  String get workflowChooseStepAgentDesc => isId
      ? 'Agent ini yang akan menjalankan langkah.'
      : 'This agent will execute the step.';
  String get workflowSearchAgent => isId ? 'Cari agent...' : 'Search agents...';
  String get workflowNoAgents =>
      isId ? 'Agent belum tersedia' : 'No agents available';
  String get workflowUntitledAgent =>
      isId ? 'Agen tanpa nama' : 'Untitled agent';
  String get workflowBuiltinVars =>
      isId ? 'Variabel Built-in' : 'Built-in Variables';
  String get workflowViewAll => isId ? 'Lihat Semua' : 'View All';
  String get workflowInsertVariable =>
      isId ? 'Sisipkan variabel' : 'Insert variable';
  String get workflowSchedule => isId ? 'Jadwal' : 'Schedule';
  String get workflowEvent => isId ? 'Event' : 'Event';
  String get workflowEventType => isId ? 'Jenis Event' : 'Event Type';
  String get workflowChooseEventType =>
      isId ? 'Pilih jenis event' : 'Choose event type';
  String get workflowChooseEventTypeDesc => isId
      ? 'Pilih pemicu event untuk workflow ini.'
      : 'Choose an event trigger for this workflow.';
  String get workflowSearchEvent => isId ? 'Cari event...' : 'Search events...';
  String get workflowNoEvents =>
      isId ? 'Event tidak ditemukan' : 'No events found';
  String get workflowKeyword => isId ? 'Kata Kunci' : 'Keyword';
  String get workflowKeywordHint =>
      isId ? 'mis: urgent, meeting' : 'e.g. urgent, meeting';
  String get workflowTriggerRequired =>
      isId ? 'Agar trigger berjalan' : 'Required for this trigger';
  String get workflowPriorityLow => isId ? 'Rendah' : 'Low';
  String get workflowPriorityHigh => isId ? 'Tinggi' : 'High';
  String get workflowPriorityCritical => isId ? 'Kritis' : 'Critical';
  String get workflowSilent => isId ? 'Senyap' : 'Silent';
  String get workflowAlwaysRun => isId ? 'Selalu jalan' : 'Always run';
  String get workflowChange => isId ? 'Ubah' : 'Change';
  String get workflowScheduleDesc => isId
      ? 'Workflow berjalan otomatis sesuai jadwal.'
      : 'Workflow runs automatically on a schedule.';
  String get workflowEventDesc => isId
      ? 'Workflow dipicu oleh event sistem.'
      : 'Workflow is triggered by system events.';
  String get workflowSensitiveDesc => isId
      ? 'Izinkan workflow menjalankan aksi sistem (hapus file, kirim notifikasi, dll).'
      : 'Allow workflow to perform system actions (delete files, send notifications, etc.).';
  String get workflowChooseAgent => isId ? 'Pilih agen' : 'Choose agent';
  String get workflowChooseAgentTitle => isId ? 'Pilih Agen' : 'Choose Agent';
  String get workflowNoAgentsYet => isId ? 'Belum ada agen' : 'No agents yet';
  String get workflowSearchAgentsLong => isId ? 'Cari agen' : 'Search agents';
  String get workflowNoAgentsFound =>
      isId ? 'Agen tidak ditemukan' : 'No agents found';

  // --- Module detail ---
  String get openLabel => isId ? 'Buka' : 'Open';
  String get uninstallTooltip => isId ? 'Hapus modul' : 'Uninstall';
  String get moduleEnabled => isId ? 'Modul Aktif' : 'Module Enabled';
  String get openNotes => isId ? 'Buka Catatan' : 'Open Notes';
  String get openCalendar => isId ? 'Buka Kalender' : 'Open Calendar';
  String get openWorkflows => isId ? 'Buka Workflows' : 'Open Workflows';
  String get openApiStore => isId ? 'Buka API Store' : 'Open API Store';
  String get openVmRuntime => isId ? 'Buka VM Runtime' : 'Open VM Runtime';
  String get featurePermission =>
      isId ? 'Fitur & Izin Agen' : 'Feature & Permission';
  String get notificationPermissionRequired => isId
      ? 'Izin notifikasi diperlukan.'
      : 'Notification permission required.';
  String get overlayPermissionRequired => isId
      ? 'Izinkan "Tampil di atas aplikasi lain" untuk menggunakan bubble.'
      : 'Allow "Display over other apps" to use the bubble.';
  String get urlIntentsEnabled => isId
      ? 'Izin membuka aplikasi diaktifkan.'
      : 'App launch permission enabled.';
  String get alarmsPermissionRequired => isId
      ? 'Izinkan "Alarm & Pengingat" di pengaturan untuk mengaktifkan Workflow.'
      : 'Grant "Alarms & Reminders" permission in settings to enable Workflows.';
  String moduleUninstallDialog(String name) => isId
      ? 'Hapus $name? Pengaturan dan izin akan dilepas.'
      : 'Remove $name? Settings and permissions will be detached.';
  String get moduleEnabledDesc => isId
      ? 'Nyalakan untuk mengaktifkan modul ini.'
      : 'Turn on to activate this module.';
  String get shizukuSectionTitle => 'App Agentic - Shizuku';
  String get shizukuSectionDesc => isId
      ? 'Shizuku memberikan akses shell-level untuk otomatisasi perangkat (wake, unlock, input gesture). Pastikan Shizuku aktif sebelum mengaktifkan toggle.'
      : 'Shizuku provides shell-level access for device automation (wake, unlock, input gestures). Make sure Shizuku is running before enabling the toggle.';
  String get shizukuStatusReady => isId
      ? 'Shizuku aktif dan permission sudah diberikan.'
      : 'Shizuku is running and permission is granted.';
  String get shizukuStatusPermissionNeeded => isId
      ? 'Shizuku aktif, tapi permission Meow Agent belum diberikan.'
      : 'Shizuku is running, but Meow Agent permission is not granted yet.';
  String get shizukuStatusUnavailable => isId
      ? 'Shizuku belum tersedia. Jalankan Shizuku dulu, lalu cek ulang.'
      : 'Shizuku is not available yet. Start Shizuku, then check again.';
  String get shizukuStatusChecking =>
      isId ? 'Mengecek status Shizuku...' : 'Checking Shizuku status...';
  String get shizukuStatusUnknown => isId
      ? 'Status Shizuku belum dicek.'
      : 'Shizuku status has not been checked yet.';
  String get shizukuStatusRequestPending => isId
      ? 'Request permission dikirim. Jika dialog Shizuku muncul, izinkan lalu kembali ke Meow Agent.'
      : 'Permission request sent. If Shizuku shows a dialog, allow it and return to Meow Agent.';
  String shizukuStatusError(String message) => isId
      ? 'Gagal mengecek Shizuku: $message'
      : 'Could not check Shizuku: $message';
  String get accessibilityRequired => isId
      ? 'Aktifkan Meow Agent Accessibility Service, lalu kembali ke Meow Agent.'
      : 'Enable Meow Agent Accessibility Service, then return to Meow Agent.';
  String get accessibilityPermTitle => isId
      ? 'Izin Accessibility Diperlukan'
      : 'Accessibility Permission Required';
  String get accessibilityPermBody => isId
      ? 'App Agentic memerlukan Accessibility Service untuk membaca dan mengontrol layar aplikasi lain. '
            'Buka Settings dan aktifkan "Meow Agent Automation".'
      : 'App Agentic requires Accessibility Service to read and control other app screens. '
            'Open Settings and enable "Meow Agent Automation".';
  String get overlayPermTitle => isId
      ? 'Izin Tampil di Atas Aplikasi Lain'
      : 'Display Over Other Apps Permission';
  String get overlayPermBodyAgentic => isId
      ? 'App Agentic juga butuh izin "Tampil di atas aplikasi lain" untuk menampilkan border progres saat agen sedang mengontrol layar. '
            'Buka Settings dan aktifkan izin tersebut untuk Meow Agent.'
      : 'App Agentic also needs the "Display over other apps" permission to render the progress border while the agent is controlling the screen. '
            'Open Settings and enable it for Meow Agent.';
  String get appAgenticPrereqsTitle => isId
      ? 'Syarat App Agentic'
      : 'App Agentic Requirements';
  String get appAgenticPrereqsDesc => isId
      ? 'Toggle App Agentic baru bisa diaktifkan setelah kedua izin Android di bawah ini diberikan.'
      : 'The App Agentic toggle can only be enabled after both Android permissions below are granted.';
  String get appAgenticPrereqAccessibility => isId
      ? 'Layanan Aksesibilitas (Meow Agent Automation)'
      : 'Accessibility Service (Meow Agent Automation)';
  String get appAgenticPrereqOverlay => isId
      ? 'Tampil di atas aplikasi lain'
      : 'Display over other apps';
  String get appAgenticPrereqsAllMet => isId
      ? 'Semua izin sudah aktif. Toggle App Agentic siap dinyalakan.'
      : 'All permissions granted. App Agentic toggle is ready.';
  String get appAgenticPrereqsNotMet => isId
      ? 'Aktifkan dulu izin yang ditandai untuk bisa menyalakan App Agentic.'
      : 'Grant the missing permissions before enabling App Agentic.';
  String get appAgenticBtnAccessibility => isId
      ? 'Aktifkan Aksesibilitas'
      : 'Enable Accessibility';
  String get appAgenticBtnOverlay => isId
      ? 'Izinkan Overlay'
      : 'Allow Overlay';
  String get shizukuSupportRequired => isId
      ? 'Aktifkan dukungan Shizuku terlebih dahulu.'
      : 'Enable Shizuku support first.';
  String get devicePinTitle => isId ? 'PIN Perangkat' : 'Device PIN';
  String get devicePinDescription => isId
      ? 'PIN ini akan digunakan untuk membuka kunci perangkat secara otomatis. '
            'PIN harus sesuai dengan yang Anda gunakan untuk membuka device. '
            'PIN akan disimpan dengan enkripsi aman.'
      : 'This PIN will be used to automatically unlock the device. '
            'PIN must match the one you use to unlock your device. '
            'PIN will be stored with secure encryption.';
  String get devicePinInputHint =>
      isId ? 'Masukkan PIN perangkat Anda' : 'Enter your device PIN';
  String get devicePinNewTitle => isId ? 'PIN Baru' : 'New PIN';
  String get devicePinSave => isId ? 'Simpan' : 'Save';
  String get devicePinCancel => isId ? 'Batal' : 'Cancel';
  String get devicePinEmpty =>
      isId ? 'PIN tidak boleh kosong' : 'PIN cannot be empty';
  String get devicePinMinLength =>
      isId ? 'PIN minimal 4 digit' : 'PIN must be at least 4 digits';
  String get devicePinVerifyTitle => isId ? 'Verifikasi PIN' : 'Verify PIN';
  String get devicePinVerifyHint =>
      isId ? 'Masukkan PIN yang sudah tersimpan' : 'Enter the stored PIN';
  String get devicePinVerifyButton => isId ? 'Verifikasi' : 'Verify';
  String get devicePinEdit => isId ? 'Edit' : 'Edit';
  String get devicePinMismatch =>
      isId ? 'PIN tidak sesuai' : 'PIN does not match';
  String get devicePinVerifyRequired =>
      isId ? 'Masukkan PIN yang sudah tersimpan' : 'Enter the stored PIN';
  String get devicePinEncrypted => '[Encrypted PIN]';
  String get checkStatus => isId ? 'Cek Status' : 'Check Status';
  String get requestPermission => 'Request Permission';
  String get setupGuide => 'Setup Guide';

  // Battery optimization (Super Power module)
  String get batteryOptTitle =>
      isId ? 'Optimisasi Baterai' : 'Battery Optimization';
  String get batteryOptDesc => isId
      ? 'Agar workflow terjadwal berjalan andal di latar belakang, nonaktifkan optimisasi baterai untuk Meow Agent.'
      : 'For scheduled workflows to run reliably in the background, disable battery optimization for Meow Agent.';
  String get batteryOptExcluded => isId
      ? 'Meow Agent dikecualikan dari optimisasi baterai. Workflow latar belakang akan berjalan andal.'
      : 'Meow Agent is excluded from battery optimization. Background workflows will run reliably.';
  String get batteryOptNotExcluded => isId
      ? 'Meow Agent belum dikecualikan. Android mungkin menghentikan workflow latar belakang.'
      : 'Meow Agent is not excluded. Android may kill background workflows.';
  String get batteryOptRequest =>
      isId ? 'Nonaktifkan Optimisasi Baterai' : 'Disable Battery Optimization';
  String get batteryOptManage =>
      isId ? 'Kelola Pengaturan Baterai' : 'Manage Battery Settings';

  // VM Runtime module — simplified one-tap install/start/stop flow.
  String get vmRuntimeTitle => isId ? 'VM Runtime' : 'VM Runtime';
  String get vmRuntimeSubtitle => isId
      ? 'Linux lokal di dalam Meow. Binary dan image diunduh dari app saat kamu install.'
      : 'A local Linux runtime inside Meow. Binaries and image download in-app when you install.';
  String get vmInstallRuntime => isId ? 'Install Runtime' : 'Install Runtime';
  String get vmStartRuntime => isId ? 'Mulai Runtime' : 'Start Runtime';
  String get vmStopRuntime => isId ? 'Hentikan Runtime' : 'Stop Runtime';
  String get vmReinstallRuntime => isId ? 'Install Ulang' : 'Reinstall';
  String get vmOpenTerminal => isId ? 'Buka Terminal' : 'Open Terminal';
  String get vmTerminalTitle => isId ? 'Terminal' : 'Terminal';
  String get vmTerminalClear => isId ? 'Bersihkan' : 'Clear';
  String get vmTerminalHint => isId ? 'Ketik perintah…' : 'Type a command…';
  String get vmRuntimeReady =>
      isId ? 'Runtime siap dipakai agent.' : 'Runtime is ready for agents.';
  String get vmRuntimeIdle => isId
      ? 'Runtime sudah terpasang. Mulai untuk dipakai agent.'
      : 'Runtime is installed. Start it to let agents use it.';
  String get vmRuntimeNeedInstall => isId
      ? 'Belum ada runtime terpasang. Tap Install untuk mengunduh binary kecil dan image runtime.'
      : 'No runtime installed yet. Tap Install to download the small binaries and runtime image.';
  String get vmRuntimeStarting =>
      isId ? 'Memulai runtime...' : 'Starting runtime...';
  String get vmRuntimeDownloading => isId
      ? 'Mengunduh runtime. Proses berjalan di latar belakang.'
      : 'Downloading runtime. Running in background.';

  // Plugin section
  String get vmPluginsTitle => isId ? 'Plugin' : 'Plugins';
  String get vmPluginsSubtitle => isId
      ? 'Toolchain bahasa & CLI yang bisa dipakai agent di dalam runtime.'
      : 'Language toolchains and CLIs the agent can use inside the runtime.';
  String get vmPluginInstall => isId ? 'Install' : 'Install';
  String get vmPluginInstalling => isId ? 'Memasang...' : 'Installing...';
  String get vmPluginInstalled => isId ? 'Terpasang' : 'Installed';
  String get vmPluginUninstall => isId ? 'Uninstall' : 'Uninstall';
  String get vmPluginRunRequired => isId
      ? 'Mulai runtime dulu sebelum memasang plugin.'
      : 'Start the runtime before installing plugins.';
  String vmPluginConfirmTitle(String name) =>
      isId ? 'Pasang $name?' : 'Install $name?';
  String vmPluginConfirmBody(String name, int sizeMb) => isId
      ? '$name akan diunduh dan dipasang di dalam runtime. Estimasi $sizeMb MB. '
            'Proses berjalan di latar belakang.'
      : '$name will be downloaded and installed inside the runtime. '
            'Estimated $sizeMb MB. Runs in the background.';
  String vmPluginInstallSuccess(String name) =>
      isId ? '$name terpasang.' : '$name installed.';
  String vmPluginInstallFailed(String name) =>
      isId ? 'Gagal memasang $name.' : 'Failed to install $name.';
  String get vmPluginEstimatedSize => isId ? 'Ukuran' : 'Size';
  String get vmNativeUnavailable => isId
      ? 'Native VM runtime belum tersambung di build ini.'
      : 'Native VM runtime is not wired up in this build yet.';
  String get vmStatusReady =>
      isId ? 'Runtime siap digunakan.' : 'Runtime is ready.';
  String get vmStatusUnavailable =>
      isId ? 'Native belum tersambung' : 'Native not connected';
  String get vmStatusNotInstalled => isId ? 'Belum terpasang' : 'Not installed';
  String get vmStatusDownloading => isId ? 'Sedang mengunduh' : 'Downloading';
  String get vmStatusInstalled =>
      isId ? 'Terpasang, belum berjalan' : 'Installed, not running';
  String get vmStatusStarting => isId ? 'Memulai' : 'Starting';
  String get vmStatusRunning => isId ? 'Berjalan' : 'Running';
  String get vmStatusStopped => isId ? 'Berhenti' : 'Stopped';
  String get vmStatusError => isId ? 'Runtime error' : 'Runtime error';
  String vmPreviewPort(int port) => isId
      ? 'Preview lokal: 127.0.0.1:$port'
      : 'Local preview: 127.0.0.1:$port';
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
      ? 'Ini akan menghapus agen ini secara permanen dari database beserta folder workspace dan semua file user di dalamnya.\n\nTindakan ini tidak bisa dibatalkan.'
      : 'This will permanently delete this agent from the database along with its workspace folder and all user files inside.\n\nThis action cannot be undone.';
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
  String moduleInstalledForPreviousRequest(String name) => isId
      ? 'Permintaan tadi membutuhkan $name. $name sudah terpasang; buka modulnya untuk mengecek izin yang diperlukan, lalu coba lagi.'
      : 'The previous request needs $name. $name is installed now; open the module to check the required permissions, then try again.';
  String installModuleAction(String name) =>
      isId ? 'Pasang $name' : 'Install $name';
  String openModuleAction(String name) => isId ? 'Buka $name' : 'Open $name';
  String moduleAlreadyInstalled(String name) =>
      isId ? '$name sudah terpasang.' : '$name is already installed.';
  String moduleInstallUnavailable(String name) => isId
      ? 'Modul "$name" belum tersedia di daftar modul.'
      : 'Module "$name" is not available in the module list.';
  String moduleMissingTitle(String name) =>
      isId ? '$name belum terpasang' : '$name is not installed';
  String moduleMissingBody(String name) => isId
      ? 'Tombol ini mengarah ke $name, tapi modulnya sudah dilepas atau belum terpasang. Pasang lagi untuk membuka pengaturan dan izin.'
      : 'This button points to $name, but the module has been removed or is not installed yet. Install it again to open settings and permissions.';
  String get moduleUnknownTitle =>
      isId ? 'Modul tidak tersedia' : 'Module unavailable';
  String get moduleUnknownBody => isId
      ? 'Link ini mengarah ke modul yang tidak tersedia di daftar modul saat ini.'
      : 'This link points to a module that is not available in the current module list.';
  String get active => isId ? 'Aktif' : 'Active';
  String get disabled => isId ? 'Nonaktif' : 'Disabled';
  String get failedLoadModules =>
      isId ? 'Gagal memuat modul.' : 'Failed to load modules.';
  String get noModulesYet => isId ? 'Belum ada modul' : 'No modules yet';
  String get noModulesBrowse => isId
      ? 'Tap "Tambah" untuk melihat modul yang tersedia.'
      : 'Tap "Add" to browse available modules.';

  // Module descriptions (store & detail screens).
  String get moduleDescDeviceContext => isId
      ? 'Biarkan agen membaca status perangkat, aplikasi aktif, koneksi, papan klip, dan membuka aplikasi, URL, atau pengaturan sistem.'
      : 'Let agents read device state, active app context, connectivity, clipboard, and launch apps, URLs, or system settings.';
  String get moduleDescNotification => isId
      ? 'Kelola notifikasi agen: baca dan ringkas notifikasi Android, kirim notifikasi lokal, dan tampilkan tombol cepat papan klip.'
      : 'Manage agent notifications: read and summarize Android notifications, send local notifications, and show a clipboard quick action.';
  String get moduleDescNotes => isId
      ? 'Buat dan kelola catatan markdown untuk kamu dan agenmu. Lapisan memori lokal yang persisten.'
      : 'Create and manage markdown notes for you and your agents. Local-first persistent memory layer.';
  String get moduleDescFiles => isId
      ? 'Buat, baca, edit, hapus, dan kelola file di workspace agen. Terbatas hanya di direktori workspace.'
      : 'Create, read, edit, delete, and organize files within the agent workspace. Sandboxed to the workspace directory only.';
  String get moduleDescCalendar => isId
      ? 'Kalender lokal untuk menjadwalkan event dan pengingat. Agen dapat membuat dan mengelola jadwalmu.'
      : 'Local calendar for scheduling events and reminders. Agent can create and manage your schedule.';
  String get moduleDescWorkflows => isId
      ? 'Jadwalkan tugas otomatis agent dengan notifikasi. Buat workflow yang menjalankan prompt di waktu tertentu atau berkala.'
      : 'Schedule automated agent tasks with notifications. Create workflows that run prompts at specific times or intervals.';
  String get moduleDescWeb => isId
      ? 'Fetch API HTTP dan simpan endpoint yang bisa dipakai ulang. Semua agent bisa memanggil API tersimpan lewat nama.'
      : 'Fetch HTTP APIs and register reusable endpoints. Any agent can call stored APIs by name with auto-filled parameters.';
  String get moduleDescVm => isId
      ? 'Install dan kontrol runtime Linux lokal berbasis proot untuk sesi terminal, server web dev, dan preview localhost di dalam aplikasi.'
      : 'Install and control a local proot Linux runtime for terminal sessions, web dev servers, and in-app localhost previews.';
  String get moduleDescSuperPower => isId
      ? 'Fitur lanjutan: bubble AI mengambang dan kontrol perangkat via Shizuku untuk otomatisasi tingkat lanjut.'
      : 'Advanced features: floating AI bubble overlay and Shizuku-powered device control for next-level automation.';

  // --- Today Prompt (module detail) ---
  String get todayPromptTitle => isId ? 'Prompt Hari Ini' : 'Today\'s Prompt';
  String get todayPromptSubtitle => isId
      ? 'Ide prompt yang bisa kamu coba dengan modul ini. Berganti otomatis tiap beberapa jam.'
      : 'A prompt idea you can try with this module. Refreshes automatically every few hours.';
  String get todayPromptCopy => isId ? 'Salin' : 'Copy';
  String get todayPromptCopied => isId ? 'Prompt disalin.' : 'Prompt copied.';
  String get todayPromptShuffle => isId ? 'Ganti' : 'Shuffle';

  /// Example prompts a user can try, grouped per module. These are user-facing
  /// suggestions shown in the "Today's Prompt" card, not LLM engine prompts.
  List<String> modulePrompts(String moduleId) {
    switch (moduleId) {
      case 'device_context':
        return isId
            ? const [
                'Berapa persen baterai sekarang dan apakah sedang mengisi?',
                'Aku terhubung ke WiFi atau data seluler?',
                'Buka pengaturan Bluetooth.',
                'Apa aplikasi yang sedang aktif di layar?',
                'Mode jangan ganggu sedang aktif atau tidak?',
              ]
            : const [
                'What\'s my battery level and is it charging?',
                'Am I on WiFi or mobile data right now?',
                'Open the Bluetooth settings.',
                'Which app is currently in the foreground?',
                'Is Do Not Disturb mode on?',
              ];
      case 'notification_intelligence':
        return isId
            ? const [
                'Ringkas notifikasi yang masuk hari ini.',
                'Ada pesan penting yang belum kubaca?',
                'Beri tahu aku kalau ada notifikasi dari email.',
                'Balas notifikasi terakhir dengan "Oke, segera."',
              ]
            : const [
                'Summarize the notifications I got today.',
                'Any important messages I haven\'t read?',
                'Let me know when an email notification arrives.',
                'Reply to the last notification with "Okay, on it."',
              ];
      case 'notes':
        return isId
            ? const [
                'Buat catatan ide untuk proyek minggu ini.',
                'Catat daftar belanja: kopi, susu, telur.',
                'Cari catatan yang menyebut "meeting".',
                'Ringkas semua catatanku jadi poin-poin.',
              ]
            : const [
                'Create a note with ideas for this week\'s project.',
                'Save a shopping list: coffee, milk, eggs.',
                'Find notes that mention "meeting".',
                'Summarize all my notes into bullet points.',
              ];
      case 'files':
        return isId
            ? const [
                'Buat file todo.md berisi tugas hari ini.',
                'Tampilkan isi file catatan terbaru.',
                'Rapikan file di workspace ke dalam folder.',
                'Hapus file sementara yang sudah tidak dipakai.',
              ]
            : const [
                'Create a todo.md file with today\'s tasks.',
                'Show me the contents of my latest note file.',
                'Organize the workspace files into folders.',
                'Delete temporary files I no longer need.',
              ];
      case 'calendar':
        return isId
            ? const [
                'Jadwalkan meeting besok jam 10 pagi.',
                'Apa saja agenda ku minggu ini?',
                'Ingatkan aku bayar tagihan tanggal 25.',
                'Pindahkan janji sore ke jam 4.',
              ]
            : const [
                'Schedule a meeting tomorrow at 10 AM.',
                'What\'s on my agenda this week?',
                'Remind me to pay the bill on the 25th.',
                'Move my afternoon appointment to 4 PM.',
              ];
      case 'workflows':
        return isId
            ? const [
                'Buat workflow yang merangkum berita tiap pagi jam 7.',
                'Jalankan ringkasan harian sekarang.',
                'Buat pengingat minum air tiap 2 jam.',
                'Workflow apa saja yang sedang aktif?',
              ]
            : const [
                'Create a workflow that summarizes news every morning at 7.',
                'Run my daily summary now.',
                'Make a reminder to drink water every 2 hours.',
                'Which workflows are currently active?',
              ];
      case 'web':
        return isId
            ? const [
                'Daftarkan API cuaca dan panggil untuk kota ku.',
                'Ambil data dari endpoint yang sudah tersimpan.',
                'Cek harga kripto lewat API tersimpan.',
                'API apa saja yang sudah aku simpan?',
              ]
            : const [
                'Register a weather API and call it for my city.',
                'Fetch data from a stored endpoint.',
                'Check crypto prices via a stored API.',
                'Which APIs have I already saved?',
              ];
      case 'vm':
        return isId
            ? const [
                'Jalankan "ls -la" di runtime.',
                'Cek versi Node.js yang terpasang.',
                'Buat folder proyek baru lewat terminal.',
                'Tampilkan penggunaan disk di runtime.',
              ]
            : const [
                'Run "ls -la" inside the runtime.',
                'Check the installed Node.js version.',
                'Create a new project folder via the terminal.',
                'Show disk usage inside the runtime.',
              ];
      case 'communication':
        return isId
            ? const [
                'Telepon kontak bernama "Budi".',
                'Kirim SMS ke Ibu: "Aku pulang malam."',
                'Cari nomor kontak "Andi".',
                'Telepon nomor terakhir yang kuhubungi.',
              ]
            : const [
                'Call the contact named "Budi".',
                'Send an SMS to Mom: "I\'ll be home late."',
                'Look up the contact "Andi".',
                'Call the last number I dialed.',
              ];
      case 'super_power':
        return isId
            ? const [
                'Buka WhatsApp dan kirim pesan ke grup keluarga.',
                'Bantu aku isi form di aplikasi ini.',
                'Tap tombol kirim di layar.',
                'Scroll ke bawah dan baca isi halaman.',
              ]
            : const [
                'Open WhatsApp and send a message to the family group.',
                'Help me fill out the form in this app.',
                'Tap the send button on screen.',
                'Scroll down and read the page content.',
              ];
      default:
        return isId
            ? const ['Apa yang bisa modul ini lakukan?']
            : const ['What can this module do?'];
    }
  }
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

  /// Snackbar shown when the user denies a permission via the OS dialog.
  String permissionDeniedMessage(String permissionLabel) => isId
      ? 'Izin "$permissionLabel" diperlukan untuk fitur ini.'
      : 'The "$permissionLabel" permission is required for this feature.';

  /// Dialog body shown when a permission is permanently denied — user must
  /// re-grant from Android system settings.
  String permissionPermanentlyDeniedBody(String permissionLabel) => isId
      ? 'Izin "$permissionLabel" sudah diblokir. Buka pengaturan sistem untuk mengaktifkannya kembali.'
      : 'The "$permissionLabel" permission has been blocked. Open system settings to re-enable it.';

  /// Human-readable label for each Android permission type.
  String permissionLabel(String permissionKey) {
    switch (permissionKey) {
      case 'storage':
        return isId ? 'Penyimpanan' : 'Storage';
      case 'notification':
        return isId ? 'Notifikasi' : 'Notification';
      case 'bluetoothConnect':
        return 'Bluetooth';
      case 'location':
        return isId ? 'Lokasi' : 'Location';
      case 'contacts':
        return isId ? 'Kontak' : 'Contacts';
      case 'callPhone':
        return isId ? 'Telepon' : 'Phone';
      case 'sendSms':
        return 'SMS';
      case 'phoneState':
        return isId ? 'Status Telepon' : 'Phone State';
      case 'systemAlertWindow':
        return isId ? 'Overlay' : 'Overlay';
      default:
        return permissionKey;
    }
  }
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
  String get viewMarkdown => isId ? 'Lihat Markdown' : 'View Markdown';
  String get seeMore => isId ? 'Lihat selengkapnya' : 'See more';
  String get cannotReplyEmpty => isId
      ? 'Tidak bisa membalas pesan kosong.'
      : 'Cannot reply to an empty message.';

  String modelUpdated(String provider, String model) => isId
      ? 'Model aktif sudah diperbarui.\n\n• Provider: $provider\n• Model: $model'
      : 'Active model updated.\n\n• Provider: $provider\n• Model: $model';

  String get noProviderOrModel => isId
      ? 'Provider atau model untuk agent ini belum tersedia.'
      : 'No provider or models are available for this agent.';

  String chooseModelPrompt(String selected) => isId
      ? '🎛️ Pilih model untuk agent ini.\n\n✅ Model aktif sekarang: $selected'
      : '🎛️ Choose a model for this agent.\n\n✅ Current model: $selected';

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

  // --- Chat slash command responses ---
  String get chatHistoryCleared => isId
      ? 'Riwayat chat, task aktif, dan konteks dibersihkan total.'
      : 'Chat history, active tasks, and context fully cleared.';
  String get contextReset => isId
      ? '✓ Konteks direset. Riwayat lama tetap terlihat di layar, tapi data history, task, dan konteks sesi ini sudah dikosongkan.'
      : '✓ Context reset. Older messages stay visible on screen, but this session\'s stored history, tasks, and context are cleared.';
  String get newSessionStarted => isId
      ? '✨ Sesi baru dimulai. Saya mulai dari awal yang bersih.'
      : '✨ New session started. I\'m beginning with a clean slate.';
  String sessionStartedWithId(String id) => isId
      ? '✨ Sesi baru dimulai (kode: $id). Saya mulai dari awal yang bersih.'
      : '✨ New session started (code: $id). I\'m beginning with a clean slate.';
  String newSessionStartedWithResume(
    String newId,
    String previousId,
    String previousTitle,
  ) {
    final hasTitle =
        previousTitle.isNotEmpty && previousTitle != '(empty session)';
    if (isId) {
      final tail = hasTitle
          ? '\n\nUntuk lanjut ke sesi sebelumnya ($previousTitle), ketik /resume $previousId.'
          : '\n\nUntuk lanjut ke sesi sebelumnya, ketik /resume $previousId.';
      return '✨ Sesi baru dimulai (kode: $newId). Saya mulai dari awal yang bersih.$tail';
    }
    final tail = hasTitle
        ? '\n\nTo continue the previous session ($previousTitle), type /resume $previousId.'
        : '\n\nTo continue the previous session, type /resume $previousId.';
    return '✨ New session started (code: $newId). I\'m beginning with a clean slate.$tail';
  }

  String sessionResumed(String id) => isId
      ? '↩️ Melanjutkan sesi $id. Konteks sesi itu kembali aktif.'
      : '↩️ Resumed session $id. That session\'s context is active again.';
  String sessionNotFound(String id) => isId
      ? '⚠️ Sesi "$id" tidak ditemukan. Ketik /history untuk melihat sesi yang tersedia.'
      : '⚠️ Session "$id" not found. Type /history to see available sessions.';
  String get resumeUsageHint => isId
      ? '⚠️ Gunakan: /resume {kode-sesi}\nKetik /history untuk melihat daftar sesi.'
      : '⚠️ Usage: /resume {session-code}\nType /history to see available sessions.';
  String get resumeUsageNoSessions => isId
      ? 'Belum ada sesi lain untuk dilanjutkan.'
      : 'There are no other sessions to resume yet.';
  String resumeUsageHeader(int count) => isId
      ? 'Sesi tersedia ($count). Pakai /resume {kode}:'
      : 'Available sessions ($count). Use /resume {code}:';
  String get historyEmpty =>
      isId ? '📋 Belum ada riwayat sesi.' : '📋 No session history yet.';
  String historyHeader(int count) =>
      isId ? '📋 Riwayat sesi ($count):' : '📋 Session history ($count):';
  String get historyResumeHint => isId
      ? 'Ketik /resume {kode-sesi} untuk melanjutkan.'
      : 'Type /resume {session-code} to continue.';
  String get noProviderConnected => isId
      ? '⚠️ Tidak ada provider terhubung ke agen ini.'
      : '⚠️ No provider connected to this agent.';
  String unknownCommand(String cmd) => isId
      ? 'Perintah tidak dikenal: $cmd\nKetik /help untuk daftar perintah yang tersedia.'
      : 'Unknown command: $cmd\nType /help for available commands.';
  String noWorkflows(String agentName) => isId
      ? '📋 Agent *$agentName* belum memiliki workflow.\nBuka modul Workflow untuk membuat workflow otomatis.'
      : '📋 Agent *$agentName* has no workflows assigned.\nOpen the Workflow module to create automated workflows.';
  String workflowListHeader(int count) => isId
      ? '📋 Workflow ($count) untuk agent ini:'
      : '📋 Workflows ($count) for this agent:';
  String get debugOffForLog => isId
      ? 'Debug LLM (Dev) mati. Nyalakan di Pengaturan untuk menggunakan /log.'
      : 'Debug LLM (Dev) is off. Turn it on in Settings to use /log.';
  String get noRuntimeLog => isId
      ? 'Tidak ada runtime log untuk perintah terakhir.'
      : 'No runtime log recorded for the last command.';
  String get runtimeLogHeader =>
      isId ? 'Runtime log (perintah terakhir)' : 'Runtime log (last command)';
  String get noRuntimeSteps => isId
      ? 'Belum ada langkah runtime tercatat.'
      : 'No runtime steps have been recorded yet.';
  String get debugOffForClearlog => isId
      ? 'Debug LLM (Dev) mati. Nyalakan di Pengaturan untuk menggunakan /clearlog.'
      : 'Debug LLM (Dev) is off. Turn it on in Settings to use /clearlog.';
  String get runtimeLogCleared =>
      isId ? 'Runtime debug log dibersihkan.' : 'Runtime debug log cleared.';

  // --- Status report (/status) ---
  String statusAgentTitle(String name) =>
      isId ? '📊 Status Agen' : '📊 Agent Status';
  String statusConnected(String provider, String model) => isId
      ? 'Agent terhubung ke provider $provider dengan model $model.'
      : 'Connected to provider $provider using model $model.';
  String get statusConnectionSection => isId ? 'Koneksi' : 'Connection';
  String get statusTokenSection => isId ? 'Token sesi' : 'Session tokens';
  String get statusDetails => isId ? 'Detail:' : 'Details:';
  String get statusApp =>
      isId ? 'Aplikasi: Meow Agent v1.0.0' : 'App: Meow Agent v1.0.0';
  String statusActiveAgent(String name) =>
      isId ? 'Agen aktif: $name' : 'Active agent: $name';
  String statusProvider(String provider) =>
      isId ? 'Provider: $provider' : 'Provider: $provider';
  String statusModel(String model) => isId ? 'Model: $model' : 'Model: $model';
  String statusMessages(int count) =>
      isId ? 'Pesan tersimpan: $count' : 'Stored messages: $count';
  String statusTotalTokens(int total, int calls) => isId
      ? 'Total: $total token ($calls panggilan LLM)'
      : 'Total: $total tokens ($calls LLM calls)';
  String statusInputTokens(int count) =>
      isId ? 'Input: $count token' : 'Input: $count tokens';
  String statusOutputTokens(int count) =>
      isId ? 'Output: $count token' : 'Output: $count tokens';
  String statusContextPressure(int estimated, int max, String pct) => isId
      ? 'Tekanan konteks: $estimated/$max ($pct%)'
      : 'Context pressure: $estimated/$max ($pct%)';
  String get noActiveAgent =>
      isId ? 'Tidak ada agen aktif.' : 'No active agent.';

  // --- Compact ---
  String get cannotCompact => isId
      ? '⚠️ Tidak bisa compact: tidak ada provider terhubung.'
      : '⚠️ Cannot compact: no provider connected.';
  String contextAlreadyCompact(int count, int tokens, int max) => isId
      ? '✓ Konteks sudah ringkas ($count pesan, ~$tokens tokens / $max max).'
      : '✓ Context already compact ($count messages, ~$tokens tokens / $max max).';
  String get compacting =>
      isId ? '⏳ Mengompresi konteks...' : '⏳ Compacting context...';
  String contextCompacted(int count, int tokens) => isId
      ? '✓ Konteks dikompresi: $count pesan (~$tokens tokens).'
      : '✓ Context compacted: $count messages (~$tokens tokens).';
  String compactFailed(String error) =>
      isId ? '⚠️ Kompresi gagal: $error' : '⚠️ Compact failed: $error';
  String contextExhausted(int limit) => isId
      ? 'Konteks penuh — percakapan mencapai batas $limit token.\n'
            '- Mulai **chat baru** untuk memulai ulang\n'
            '- **Tambah panjang konteks** di pengaturan agen\n'
            '- **Aktifkan auto-compact** di pengaturan agen untuk merangkum otomatis pesan lama'
      : 'Context exhausted — conversation reached $limit token limit.\n'
            '- Start a **new chat** for a clean slate\n'
            '- **Increase context length** in agent settings\n'
            '- **Enable auto-compact** in agent settings to automatically summarize old messages';
  String autoCompacted(int count) => isId
      ? '🔄 Konteks auto-compact (threshold 80% tercapai). $count pesan tersisa.'
      : '🔄 Context auto-compacted (threshold 80% reached). $count messages remaining.';

  // --- Confirm buttons ---
  String get accept => isId ? 'Terima' : 'Accept';
  String get always => isId ? 'Selalu' : 'Always';
  String get reject => isId ? 'Tolak' : 'Reject';

  // --- Date separator ---
  String get today => isId ? 'Hari ini' : 'Today';
  String get yesterday => isId ? 'Kemarin' : 'Yesterday';

  // --- Reply quote ---
  String get you => isId ? 'Kamu' : 'You';
  String get agentLabel => isId ? 'Agen' : 'Agent';

  // --- File attachment ---
  String maxFilesExceeded(int max) => isId
      ? 'Maks $max file. Hapus satu sebelum menambah.'
      : 'Max $max files allowed. Remove one before adding more.';
  String fileTooLarge(String name) => isId
      ? '"$name" terlalu besar. Maks 5 MB.'
      : '"$name" is too large. Max size is 5 MB.';
  String fileAlreadyAttached(String name) =>
      isId ? '"$name" sudah dilampirkan.' : '"$name" is already attached.';

  // --- Help / slash command descriptions ---
  String get helpAvailableCommands =>
      isId ? '✨ Perintah tersedia' : '✨ Available commands';
  String get helpCommandHint => isId
      ? 'Ketik salah satu command di bawah ini.'
      : 'Type one of the commands below.';
  String get helpSlashClear => isId
      ? 'Hapus total riwayat, task, & konteks'
      : 'Wipe history, tasks & context';
  String get helpSlashHelp => isId ? 'Tampilkan daftar ini' : 'Show this list';
  String get helpSlashStatus =>
      isId ? 'Tampilkan info agen & konteks' : 'Show agent & context info';
  String get helpSlashContext =>
      isId ? 'Tampilkan rincian token/konteks' : 'Show token/context breakdown';
  String get helpSlashReset => isId
      ? 'Kosongkan konteks & data history sesi ini'
      : 'Clear this session context & stored history';
  String get helpSlashNewSession => isId
      ? 'Mulai sesi baru dan tampilkan kode sesi lama'
      : 'Start a new session and show the previous code';
  String get helpSlashResume => isId
      ? 'Lanjutkan sesi lama: /resume {kode}'
      : 'Resume a past session: /resume {code}';
  String get helpSlashHistory =>
      isId ? 'Tampilkan daftar sesi lama' : 'Show past session list';
  String get helpSlashModel =>
      isId ? 'Tampilkan info model saat ini' : 'Show current model info';
  String get helpSlashSetModel =>
      isId ? 'Pilih model untuk agen ini' : 'Choose model for this agent';
  String get helpSlashCompact =>
      isId ? 'Kompresi jendela konteks' : 'Compact context window';
  String get helpSlashWorkflow =>
      isId ? 'Tampilkan workflow agen ini' : 'Show workflows for this agent';
  String get helpSlashLog => isId
      ? 'Tampilkan runtime debug log terakhir'
      : 'Show last runtime debug log';
  String get helpSlashClearlog => isId
      ? 'Bersihkan runtime debug log terakhir'
      : 'Clear last runtime debug log';

  // --- Activity ---
  String activityForAgent(String name) =>
      isId ? 'untuk agent $name' : 'for agent $name';
  String get activityFromAll => isId ? 'dari semua agent' : 'from all agents';
  String get activityClearTitle =>
      isId ? 'Bersihkan Aktivitas?' : 'Clear Activity?';
  String activityClearBody(String scopeLabel) => isId
      ? 'Semua riwayat eksekusi $scopeLabel akan dihapus permanen. Lanjutkan?'
      : 'All execution history $scopeLabel will be permanently deleted. Continue?';
  String get activityClear => isId ? 'Bersihkan' : 'Clear';
  String activityCleared(int removed) =>
      isId ? '$removed riwayat dibersihkan' : '$removed entries cleared';
  String get activityOptions => isId ? 'Opsi' : 'Options';
  String get activityClearAll => isId ? 'Bersihkan Semua' : 'Clear All';
  String get activityAllAgents => isId ? 'Semua Agent' : 'All Agents';
  String get activityEmptyDesc => isId
      ? 'Riwayat eksekusi workflow akan muncul di sini'
      : 'Workflow execution history will appear here';
  String get activitySuccess => isId ? 'Berhasil' : 'Success';
  String get activityFailed => isId ? 'Gagal' : 'Failed';
  String get activityRetry => isId ? 'Coba Lagi' : 'Retry';
  String get activityRunning => isId ? 'Berjalan' : 'Running';
  String get activityRunningNow => isId ? 'Sedang Berjalan' : 'Running Now';
  String activityRunningStep(int current, int total) =>
      isId ? 'Langkah $current/$total' : 'Step $current/$total';
  String activityElapsed(String duration) =>
      isId ? 'Berlangsung $duration' : 'Elapsed $duration';

  // --- Workflow list ---
  String get wfListDeleteTitle =>
      isId ? 'Hapus Workflow?' : 'Delete Workflows?';
  String wfListDeleteMessage(int count) => isId
      ? '$count workflow akan dihapus permanen. Lanjutkan?'
      : '$count workflows will be permanently deleted. Continue?';
  String get wfListTemplates => isId ? 'Template' : 'Templates';
  String get wfListSelect => isId ? 'Pilih' : 'Select';
  String wfListSelectedCount(int count) =>
      isId ? '$count dipilih' : '$count selected';
  String get wfListDeselectAll => isId ? 'Batal pilih semua' : 'Deselect all';
  String get wfListSelectAll => isId ? 'Pilih semua' : 'Select all';
  String get wfListEmpty => isId ? 'Belum ada workflow' : 'No workflows yet';
  String get wfListEmptyDesc => isId
      ? 'Buat workflow untuk menjalankan tugas otomatis'
      : 'Create workflows to run automated tasks';
  String get wfListPickTemplate =>
      isId ? 'Pilih dari Template' : 'Pick a Template';
  String get wfListLastRun => isId ? 'Terakhir:' : 'Last run:';
  String get wfListAlarm => isId ? 'Alarm' : 'Alarm';
  String get wfListNormal => isId ? 'Normal' : 'Normal';
  String get wfListRunNow => isId ? 'Jalankan sekarang' : 'Run now';
  String get wfListRunNowEventBlocked => isId
      ? 'Trigger langsung hanya tersedia untuk workflow berbasis waktu atau interval.'
      : 'Direct trigger is only available for time- or interval-based workflows.';
  String get wfListRunNowDisabled => isId
      ? 'Aktifkan workflow ini dulu untuk menjalankannya.'
      : 'Enable this workflow first to run it.';
  String get wfListRunNowQueued => isId
      ? 'Workflow dimasukkan ke antrian eksekusi.'
      : 'Workflow queued for execution.';

  // --- Workflow log detail ---
  String get wfLogDetailTitle => isId ? 'Detail Log' : 'Log Detail';
  String get wfLogSuccess =>
      isId ? 'Berhasil dijalankan' : 'Successfully executed';
  String get wfLogFailed => isId ? 'Gagal dijalankan' : 'Execution failed';
  String get wfLogInformation => isId ? 'Informasi' : 'Information';
  String get wfLogExecutedAt => isId ? 'Waktu Eksekusi' : 'Executed At';
  String get wfLogDuration => isId ? 'Durasi' : 'Duration';
  String get wfLogOpenWorkflow => isId ? 'Buka Workflow' : 'Open Workflow';
  String get wfLogRunAgain => isId ? 'Jalankan ulang' : 'Run again';
  String get wfLogCollapse => isId ? 'Sembunyikan' : 'Collapse';
  String get wfLogShowMore => isId ? 'Lihat selengkapnya' : 'Show more';
  String get wfLogNoRuntimeDetails =>
      isId ? 'Tidak ada detail runtime.' : 'No runtime details.';
  String get wfLogDeleted =>
      isId ? 'Workflow sudah dihapus.' : 'Workflow has been deleted.';
  String get wfLogProcessLabel => isId ? 'PROSES' : 'PROCESS';
  String get wfLogStepLabel => isId ? 'LANGKAH' : 'STEP';
  String get wfLogHandoffLabel => isId ? 'DATA MASUK' : 'HANDOFF';
  String get wfLogSkippedLabel => isId ? 'DILEWATI' : 'SKIPPED';
  String get wfLogRetryLabel => isId ? 'ULANG' : 'RETRY';
  String get wfLogContinueLabel => isId ? 'LANJUT' : 'CONTINUE';
  String get wfLogStoppedLabel => isId ? 'BERHENTI' : 'STOPPED';
  String get wfLogFailedLabel => isId ? 'GAGAL' : 'FAILED';
  String get wfLogDoneLabel => isId ? 'SELESAI' : 'DONE';
  String wfLogStartingStep(int num, String name) =>
      isId ? 'Memulai langkah $num: $name' : 'Starting step $num: $name';
  String wfLogProcessStopped(int num) => isId
      ? 'Proses berhenti di langkah $num karena gagal.'
      : 'Process stopped at step $num due to failure.';

  // --- Workflow templates ---
  String get wfTemplatesTitle =>
      isId ? 'Template Workflow' : 'Workflow Templates';
  String get wfTemplatesAll => isId ? 'Semua' : 'All';
  String get wfTemplatesProductivity => isId ? 'Produktivitas' : 'Productivity';
  String get wfTemplatesMonitoring => isId ? 'Monitoring' : 'Monitoring';
  String get wfTemplatesCommunication => isId ? 'Komunikasi' : 'Communication';
  String get wfTemplatesAutomation => isId ? 'Otomatisasi' : 'Automation';
  String get wfTemplatesHealth => isId ? 'Kesehatan' : 'Health';

  // --- Notes list ---
  String get notesExportNoAgent => isId
      ? 'Tidak ada agent tersedia untuk ekspor.'
      : 'No agent available for export.';
  String notesExportedCount(int count, String agentName) => isId
      ? '$count note diekspor ke Documents/MeowAgent/Agents/$agentName/notes/'
      : '$count notes exported to Documents/MeowAgent/Agents/$agentName/notes/';
  String get notesExportTitle =>
      isId ? 'Pilih workspace agent' : 'Choose agent workspace';
  String get notesTitle => isId ? 'Notes' : 'Notes';
  String notesSelectedCount(int count) =>
      isId ? '$count dipilih' : '$count selected';
  String get notesExportToWorkspace =>
      isId ? 'Export ke workspace' : 'Export to workspace';
  String get notesSelectMultiple => isId ? 'Pilih beberapa' : 'Select multiple';
  String get notesNewNote => isId ? 'Buat Note' : 'New Note';
  String get notesSearch => isId ? 'Cari note...' : 'Search notes...';
  String get notesSelectHint => isId
      ? 'Pilih note untuk diekspor atau dihapus.'
      : 'Select notes to export or delete.';
  String get notesNoResults => isId ? 'Tidak ada hasil' : 'No results';
  String get notesEmpty => isId ? 'Belum ada note' : 'No notes yet';
  String get notesEmptyTryKeyword =>
      isId ? 'Coba kata kunci lain.' : 'Try a different keyword.';
  String get notesEmptyCreateFirst => isId
      ? 'Buat note pertamamu atau minta agen mencatat sesuatu.'
      : 'Create your first note or ask your agent to jot something down.';
  String get notesDeleteTitle => isId ? 'Hapus Note?' : 'Delete Notes?';
  String notesDeleteMessage(int count) => isId
      ? '$count note akan dihapus permanen. Lanjutkan?'
      : '$count notes will be permanently deleted. Continue?';
  String notesDeletedCount(int count) =>
      isId ? '$count note dihapus' : '$count notes deleted';

  // --- Note editor ---
  String get noteEditorTitleRequired =>
      isId ? 'Judul wajib diisi' : 'Title is required';
  String get noteEditorEditTitle => isId ? 'Edit Note' : 'Edit Note';
  String get noteEditorNewTitle => isId ? 'Note Baru' : 'New Note';
  String get noteEditorTitleHint => isId ? 'Judul note' : 'Note title';
  String get noteEditorTagsHint =>
      isId ? 'Tag (pisahkan dengan koma)' : 'Tags (comma separated)';
  String get noteEditorContentHint => isId
      ? 'Tulis konten markdown di sini...'
      : 'Write markdown content here...';

  // --- Note detail ---
  String get noteDetailDeleteTitle => isId ? 'Hapus Note?' : 'Delete Note?';
  String get noteDetailDeleteMessage => isId
      ? 'Note ini akan dihapus permanen. Lanjutkan?'
      : 'This note will be permanently deleted. Continue?';
  String get noteDetailNotFound =>
      isId ? 'Note tidak ditemukan' : 'Note not found';
  String get noteDetailPin => isId ? 'Pin' : 'Pin';
  String get noteDetailUnpin => isId ? 'Unpin' : 'Unpin';
  String noteDetailCreated(String date) =>
      isId ? 'Dibuat: $date' : 'Created: $date';
  String noteDetailUpdated(String date) =>
      isId ? 'Diperbarui: $date' : 'Updated: $date';
  String noteDetailSourceLabel(String source) =>
      isId ? 'Sumber: $source' : 'Source: $source';
  String get noteDetailEmptyContent =>
      isId ? '_Tidak ada konten_' : '_No content_';

  // --- Workspace directory ---
  String get wdDefaultFileDesc => isId ? 'File workspace' : 'Workspace file';
  String get wdFolderDesc => isId ? 'Folder' : 'Folder';
  String get wdEmptyWorkspace => isId
      ? 'Belum ada file di workspace agen ini.'
      : 'No files in this agent workspace yet.';
  String get wdCannotOpenFileManager => isId
      ? 'Tidak bisa membuka file manager.'
      : 'Could not open file manager.';
  String get wdOpenFileManager =>
      isId ? 'Buka di File Manager' : 'Open in File Manager';
  String get wdSaved => isId ? 'Tersimpan' : 'Saved';
  String get wdErrorSaving => isId ? 'Gagal menyimpan: ' : 'Error saving: ';

  // --- Setup ---
  String get setupNewAgentTitle => isId ? 'New Agent' : 'New Agent';
  String get setupApiBaseUrlHint => 'https://api.openai.com/v1';
  String get setupApiKeyHint => 'sk-...';
  String get setupModelHint => 'gpt-4.1-mini';

  // --- Confirm dialog defaults ---
  String get confirmDefaultTitle => isId ? 'Hapus Item?' : 'Delete Item?';
  String get confirmDefaultConfirm => isId ? 'Konfirmasi' : 'Confirm';
  String get confirmDefaultBody => isId
      ? 'Tindakan ini tidak dapat dibatalkan. Lanjutkan?'
      : 'This action cannot be undone. Continue?';
  String get confirmDefaultDelete => isId ? 'Hapus' : 'Delete';
  String get confirmDefaultContinue => isId ? 'Lanjutkan' : 'Continue';

  // --- Dropdown defaults ---
  String get dropdownSearch => isId ? 'Cari' : 'Search';
  String get dropdownNoResults => isId ? 'Tidak ada hasil' : 'No results';

  // --- Clipboard process ---
  String get clipboardNoProvider => isId
      ? '⚠️ Provider tidak dikonfigurasi untuk agen yang dipilih.'
      : '⚠️ Provider not configured for selected agent.';
  String get clipboardNoAgentConf => isId
      ? '⚠️ Tidak ada agen terkonfigurasi. Silakan siapkan agen dengan provider terlebih dahulu.'
      : '⚠️ No agent configured. Please set up an agent with a provider first.';
  String get clipboardProcessAgentNotFound => isId
      ? '⚠️ Agen yang dipilih tidak ditemukan.'
      : '⚠️ Selected agent not found.';

  // --- Provider list ---
  String get providerListError =>
      isId ? 'Gagal memuat provider' : 'Failed to load providers';

  // --- Calendar ---
  String get calendarTitle => isId ? 'Kalender' : 'Calendar';
  String get calendarNewEvent => isId ? 'Buat Event' : 'New Event';

  // --- Calendar event editor ---
  String get calendarEventTitleRequired =>
      isId ? 'Judul tidak boleh kosong' : 'Title cannot be empty';

  // --- Home ---
  String get homeBrandName => 'MEOW AGENT';
  String get homeModuleSubtitle =>
      isId ? 'Akses cepat untuk agenmu' : 'Quick access for your agent';

  // --- Settings ---
  String get aboutTitle => isId ? 'Tentang Meow Agent' : 'About Meow Agent';

  // --- Profile Backup (Settings → Profile section) ---
  String get profileSection => isId ? 'Profil' : 'Profile';
  String get exportProfile => isId ? 'Ekspor Profil' : 'Export Profile';
  String get exportProfileDesc => isId
      ? 'Simpan agen dan provider ke file backup.'
      : 'Save agents and providers to a backup file.';
  String get importProfile => isId ? 'Impor Profil' : 'Import Profile';
  String get importProfileDesc => isId
      ? 'Pulihkan agen dan provider dari file backup.'
      : 'Restore agents and providers from a backup file.';
  String get profileExportSuccess =>
      isId ? 'Profil berhasil diekspor.' : 'Profile exported successfully.';
  String get profileExportFailed =>
      isId ? 'Gagal mengekspor profil.' : 'Failed to export profile.';
  String get profileExportEmpty => isId
      ? 'Tidak ada agen atau provider yang bisa diekspor.'
      : 'No agents or providers available to export.';
  String profileImportSuccess(int agents, int providers) => isId
      ? '$agents agen, $providers provider berhasil diimpor.'
      : '$agents agents, $providers providers imported successfully.';
  String get profileImportNoApiKey => isId
      ? 'API key tidak disertakan dalam backup. Isi ulang di tiap provider setelah impor.'
      : 'API keys are not included in the backup. Re-enter them in each provider after importing.';
  String get profileImportMerge =>
      isId ? 'Gabung (Lewati Duplikat)' : 'Merge (Skip Duplicates)';
  String get profileImportMergeDesc => isId
      ? 'Tambahkan agen dan provider baru. Yang sudah ada tidak diubah.'
      : 'Add new agents and providers. Existing ones are kept.';
  String get profileImportReplace =>
      isId ? 'Ganti Semua' : 'Replace All';
  String get profileImportReplaceDesc => isId
      ? 'Hapus semua agen dan provider yang ada, lalu impor dari file.'
      : 'Delete all existing agents and providers, then import from the file.';
  String get profileImportReplaceConfirmTitle =>
      isId ? 'Ganti Semua Profil?' : 'Replace All Profile?';
  String get profileImportReplaceConfirmBody => isId
      ? 'Semua agen dan provider yang ada akan dihapus. Aksi ini tidak bisa dibatalkan.'
      : 'All existing agents and providers will be deleted. This cannot be undone.';
  String get profileImportInvalidFile => isId
      ? 'File tidak valid atau format tidak dikenali.'
      : 'Invalid file or unrecognized format.';
  String get profileImportPreviewTitle =>
      isId ? 'Pratinjau Impor' : 'Import Preview';
  String profileImportPreviewSummary(int agents, int providers) => isId
      ? 'File ini berisi $agents agen dan $providers provider.'
      : 'This file contains $agents agents and $providers providers.';
  String profileImportSkipped(String name, String reason) => isId
      ? '"$name" dilewati: $reason'
      : '"$name" skipped: $reason';
  String get profileImportReasonOrphanProvider =>
      isId ? 'provider tidak ditemukan' : 'provider not found';
  String get profileImportReasonDuplicate =>
      isId ? 'sudah ada' : 'already exists';
  String get profileImportButtonImport => isId ? 'Impor' : 'Import';

  // --- API Store ---
  String get apiStoreTitle => 'API Store';
  String get apiStoreEditTitle => isId ? 'Edit API' : 'Edit API';
  String get apiStoreNewTitle => isId ? 'API Baru' : 'New API';
  String get apiStoreSelectTooltip => isId ? 'Pilih' : 'Select';
  String get apiStoreSelectAll => isId ? 'Pilih Semua' : 'Select All';
  String get apiStoreDeselectAll => isId ? 'Batal Pilih Semua' : 'Deselect All';
  String get apiStoreDeleteTooltip => isId ? 'Hapus' : 'Delete';
  String apiStoreSelectedCount(int count) =>
      isId ? '$count dipilih' : '$count selected';
  String get apiStoreNoApis => isId ? 'Belum ada API' : 'No APIs yet';
  String get apiStoreNoApisDesc => isId
      ? 'Daftarkan endpoint API di sini, lalu agent mana pun bisa memanggilnya lewat chat atau workflow.'
      : 'Register an API endpoint here, then any agent can call it by name via chat or workflows.';
  String get apiStoreAddApi => isId ? 'Tambah API' : 'Add API';
  String get apiStoreRemoveApisTitle => isId ? 'Hapus API?' : 'Remove APIs?';
  String apiStoreRemoveApisMessage(int count) => isId
      ? 'Hapus $count API yang dipilih dari store?'
      : 'Remove $count selected API${count > 1 ? 's' : ''} from the store?';
  String get apiStoreRemoveApiTitle => isId ? 'Hapus API?' : 'Remove API?';
  String apiStoreRemoveApiMessage(String name) =>
      isId ? 'Hapus "$name" dari store?' : 'Remove "$name" from the store?';
  String get apiStoreRemove => isId ? 'Hapus' : 'Remove';
  String get apiStoreSectionName => isId ? 'Nama' : 'Name';
  String get apiStoreSectionUrl => 'URL';
  String get apiStoreSectionMethod => isId ? 'Metode' : 'Method';
  String get apiStoreSectionAuth => isId ? 'Autentikasi' : 'Authentication';
  String get apiStoreSectionHeaders => 'Headers';
  String get apiStoreSectionQueryParams => 'Query Parameters';
  String get apiStoreSectionBody => 'Body';
  String get apiStoreNameHint =>
      isId ? 'mis. GitHub Search API' : 'e.g. GitHub Search API';
  String get apiStoreUrlHint => 'https://api.example.com/endpoint';
  String get apiStoreBodyHint => '{"key": "value"}';
  String get apiStoreTokenHint => 'Token value';
  String get apiStoreHeaderHint =>
      isId ? 'Nama header (mis. X-API-Key)' : 'Header name (e.g. X-API-Key)';
  String get apiStoreKeyValueHint => isId ? 'Nilai key' : 'Key value';
  String get apiStoreBasicAuthHint => 'username:password';
  String get apiStoreKeyHint => 'Key';
  String get apiStoreValueHint => 'Value';
  String get apiStoreHintHint => 'Hint';
  String get apiStoreDefaultHint => 'Default';
  String get apiStoreHintForAgent =>
      isId ? 'Petunjuk untuk agent' : 'Hint for agent';
  String get apiStoreAuthNone => isId ? 'Tidak Ada' : 'None';
  String get apiStoreAuthBearer => 'Bearer Token';
  String get apiStoreAuthApiKey =>
      isId ? 'API Key di Header' : 'API Key in Header';
  String get apiStoreAuthBasic => 'Basic Auth';
  String get apiStoreModeDynamic => isId ? 'Dinamis' : 'Dynamic';
  String get apiStoreModeFixed => isId ? 'Tetap' : 'Fixed';
  String get apiStoreModeTree => 'Tree';
  String get apiStoreModeRaw => 'Raw';
  String get apiStoreAddField => isId ? 'Tambah field' : 'Add field';
  String get apiStoreAddFieldTitle => isId ? 'Tambah Field' : 'Add Field';
  String get apiStoreAddItem => isId ? 'Tambah item' : 'Add item';
  String get apiStoreNameUrlRequired =>
      isId ? 'Nama dan URL wajib diisi' : 'Name and URL are required';
  String apiStoreDynamicParams(int count) => isId
      ? '$count parameter dinamis'
      : '$count dynamic param${count > 1 ? 's' : ''}';
  String get apiStoreAdd => isId ? 'Tambah' : 'Add';
  String get apiStoreSave => isId ? 'Simpan' : 'Save';
  String get apiStoreSaving => isId ? 'Menyimpan...' : 'Saving...';
  String get apiStoreCancel => isId ? 'Batal' : 'Cancel';
  String get apiStoreCurlHint => isId
      ? 'Tempel perintah cURL dari browser, Postman, atau dokumentasi API.'
      : 'Paste a cURL command from your browser, Postman, or API docs.';
  String get apiStoreCurlParse =>
      isId ? 'Parse & Isi Form' : 'Parse & Fill Form';
  String get apiStoreCurlEmpty => isId
      ? 'Tempel perintah cURL terlebih dahulu'
      : 'Paste a cURL command first';
  String get apiStoreCurlInvalid =>
      isId ? 'Format cURL tidak valid' : 'Invalid cURL format';
  String get apiStoreCurlSuccess => isId
      ? 'cURL berhasil di-parse! Lengkapi nama API.'
      : 'cURL parsed! Fill in the API name.';

  // --- Workflow event labels ---
  String get wfEventBatteryLow =>
      isId ? '🔋 Baterai dibawah 50%' : '🔋 Battery below 50%';
  String get wfEventBatteryHigh =>
      isId ? '🔋 Baterai diatas 50%' : '🔋 Battery above 50%';
  String get wfEventBatteryFull =>
      isId ? '🔋 Baterai Penuh' : '🔋 Battery Full';
  String get wfEventChargingStart =>
      isId ? '🔌 Mulai Charging' : '🔌 Charging Start';
  String get wfEventChargingStop =>
      isId ? '🔌 Berhenti Charging' : '🔌 Charging Stop';
  String get wfEventNotifKeyword =>
      isId ? '🔔 Notifikasi (Keyword)' : '🔔 Notification (Keyword)';
  String get wfEventAppOpened => isId ? '📱 Aplikasi Dibuka' : '📱 App Opened';
  String get wfEventWifiConnected =>
      isId ? '📶 WiFi Terhubung' : '📶 WiFi Connected';
  String get wfEventWifiDisconnected =>
      isId ? '📶 WiFi Terputus' : '📶 WiFi Disconnected';

  // --- Workflow event sub labels ---
  String get wfEventBatteryLowSub => isId
      ? 'Jalan saat baterai turun di bawah 50%.'
      : 'Runs when battery drops below 50%.';
  String get wfEventBatteryHighSub => isId
      ? 'Jalan saat baterai naik di atas 50%.'
      : 'Runs when battery rises above 50%.';
  String get wfEventBatteryFullSub =>
      isId ? 'Jalan saat baterai penuh.' : 'Runs when battery is full.';
  String get wfEventChargingStartSub => isId
      ? 'Jalan saat perangkat mulai di-charge.'
      : 'Runs when device starts charging.';
  String get wfEventChargingStopSub => isId
      ? 'Jalan saat perangkat berhenti di-charge.'
      : 'Runs when device stops charging.';
  String get wfEventNotifKeywordSub => isId
      ? 'Jalan saat notifikasi mengandung kata kunci.'
      : 'Runs when a notification contains a keyword.';
  String get wfEventAppOpenedSub => isId
      ? 'Jalan saat aplikasi tertentu dibuka.'
      : 'Runs when a specific app is opened.';
  String get wfEventWifiConnectedSub => isId
      ? 'Jalan saat WiFi terhubung ke jaringan.'
      : 'Runs when WiFi connects to a network.';
  String get wfEventWifiDisconnectedSub =>
      isId ? 'Jalan saat WiFi terputus.' : 'Runs when WiFi disconnects.';

  // --- Workflow editor misc ---
  String get wfTitleRequired => isId
      ? 'Judul workflow tidak boleh kosong.'
      : 'Workflow title is required.';
  String get wfMaxWorkflows =>
      isId ? 'Maksimal 20 workflow.' : 'Max 20 workflows reached.';
  String get wfAllowSensitiveDesc => isId
      ? 'Setujui otomatis aksi yang biasanya butuh konfirmasi.'
      : 'Auto-approve actions that normally require confirmation.';
  String get wfNotifyPermRequired => isId
      ? 'Pastikan permission akses notifikasi sudah diizinkan.'
      : 'Make sure notification access permission is allowed.';
  String get wfModuleDisabled => isId
      ? 'Pastikan modul Notification sudah aktif di Modules.'
      : 'Make sure the Notification module is enabled in Modules.';
  String get wfApiCallLabel =>
      isId ? 'Panggil API tersimpan' : 'Call a stored API';
  String get wfApiSelectLabel => isId ? 'Pilih API' : 'Select API';
  String get wfConditionOnlyIfPrevSuccess => isId
      ? 'Hanya jika langkah sebelumnya berhasil'
      : 'Only if previous step succeeded';
  String get wfConditionOnlyIfPrevEmpty => isId
      ? 'Hanya jika langkah sebelumnya kosong'
      : 'Only if previous step is empty';
  String get wfConditionIfPrevShort => isId
      ? 'Jika hasil sebelumnya pendek (< 50 karakter)'
      : 'If previous result is short (< 50 chars)';
  String get wfConditionIfPrevLong => isId
      ? 'Jika hasil sebelumnya panjang (> 200 karakter)'
      : 'If previous result is long (> 200 chars)';
  String get wfConditionIfContainsSukses =>
      isId ? "Jika hasil mengandung 'sukses'" : "If result contains 'success'";
  String get wfConditionIfContainsError =>
      isId ? "Jika hasil mengandung 'error'" : "If result contains 'error'";

  // --- Built-in variable categories ---
  String get wfVarCategoryTime => isId ? 'Waktu & Tanggal' : 'Time & Date';
  String get wfVarCategoryIdentity => isId ? 'Identitas' : 'Identity';
  String get wfVarCategoryTriggerNotif =>
      isId ? 'Pemicu: Notifikasi' : 'Trigger: Notification';
  String get wfVarCategoryTriggerApp =>
      isId ? 'Pemicu: Buka Aplikasi' : 'Trigger: App Opened';
  String get wfVarCategoryTriggerBattery =>
      isId ? 'Pemicu: Baterai' : 'Trigger: Battery';
  String get wfVarCategoryStep => isId ? 'Multi-Langkah' : 'Multi-Step';

  // --- Module setting labels (used by module_detail_screen) ---
  String moduleSettingGroupTitle(String moduleId, String groupKey) {
    if (moduleId == 'device_context') {
      return switch (groupKey) {
        'power' => isId ? 'Daya' : 'Power',
        'connectivity' => isId ? 'Koneksi' : 'Connectivity',
        'apps' => isId ? 'Aplikasi' : 'Apps',
        'system' => isId ? 'Perangkat' : 'Device',
        'clipboard' => isId ? 'Papan Klip' : 'Clipboard',
        _ => groupKey,
      };
    }
    return groupKey;
  }

  String moduleSettingGroupDescription(String moduleId, String groupKey) {
    if (moduleId == 'device_context') {
      return switch (groupKey) {
        'power' =>
          isId
              ? 'Status baterai dan pengisian daya.'
              : 'Battery and charging state.',
        'connectivity' =>
          isId
              ? 'Jaringan, WiFi, seluler, dan Bluetooth.'
              : 'Network, WiFi, cellular, and Bluetooth.',
        'apps' =>
          isId
              ? 'Aplikasi aktif, statistik penggunaan, URL, pengaturan sistem, dan launching.'
              : 'Active app, usage stats, URLs, system settings, and launching.',
        'system' =>
          isId
              ? 'Penyimpanan, waktu, bahasa, dan mode sistem.'
              : 'Storage, time, language, and system mode.',
        'clipboard' =>
          isId
              ? 'Baca atau ubah isi papan klip lewat agen.'
              : 'Let agents read or update clipboard contents.',
        _ => '',
      };
    }
    return '';
  }

  (String, String) moduleSetting(
    String moduleId,
    String key,
  ) => switch (moduleId) {
    'device_context' => switch (key) {
      'allow_battery' => (
        isId ? 'Info Baterai' : 'Battery Info',
        isId
            ? 'Agen dapat membaca level baterai dan status pengisian.'
            : 'Agent can read battery level and charging status.',
      ),
      'allow_network' => (
        isId ? 'Info Jaringan' : 'Network Info',
        isId
            ? 'Agen dapat membaca tipe koneksi. Opsional: izin Lokasi & Telepon mengaktifkan SSID WiFi dan deteksi 4G/5G.'
            : 'Agent can read connection type (WiFi, cellular, etc.). Optional: Location & Phone permissions enable WiFi SSID and 4G/5G detection.',
      ),
      'allow_storage' => (
        isId ? 'Info Penyimpanan' : 'Storage Info',
        isId
            ? 'Agen dapat membaca penggunaan penyimpanan internal.'
            : 'Agent can read internal storage usage.',
      ),
      'allow_time_locale' => (
        isId ? 'Waktu & Lokal' : 'Time & Locale',
        isId
            ? 'Agen dapat membaca waktu lokal, zona waktu, dan bahasa.'
            : 'Agent can read local time, timezone, and language.',
      ),
      'allow_foreground_app' => (
        isId ? 'Deteksi Aplikasi Aktif' : 'Foreground App Detection',
        isId
            ? 'Agen dapat mendeteksi aplikasi yang sedang aktif. Membutuhkan izin Usage Stats.'
            : 'Agent can detect which app is currently active. Requires Usage Stats permission.',
      ),
      'allow_charging' => (
        isId ? 'Info Pengisian Daya' : 'Charging Info',
        isId
            ? 'Agen dapat membaca status pengisian daya dan tipe charger.'
            : 'Agent can read charging state and plug type.',
      ),
      'allow_dnd' => (
        isId ? 'Status Jangan Ganggu' : 'Do Not Disturb Status',
        isId
            ? 'Agen dapat membaca mode DND. Membutuhkan akses kebijakan notifikasi.'
            : 'Agent can read DND mode. Requires notification policy access.',
      ),
      'allow_bluetooth' => (
        isId ? 'Status Bluetooth' : 'Bluetooth Status',
        isId
            ? 'Agen dapat membaca status Bluetooth dan perangkat yang tersambung. Membutuhkan izin Nearby Devices.'
            : 'Agent can read Bluetooth state and connected devices. Requires Nearby Devices permission.',
      ),
      'allow_clipboard_read' => (
        isId ? 'Baca Papan Klip' : 'Read Clipboard',
        isId
            ? 'Agen dapat membaca teks yang sedang tersimpan di papan klip.'
            : 'Agent can read the text currently stored in the clipboard.',
      ),
      'allow_clipboard_write' => (
        isId ? 'Mengupdate Papan Klip' : 'Update Clipboard',
        isId
            ? 'Agen dapat mengganti isi papan klip dengan teks baru. Aksi ini tetap butuh konfirmasi.'
            : 'Agent can replace clipboard contents with new text. This still requires confirmation.',
      ),
      'allow_open_apps' => (
        isId ? 'Izinkan Buka Aplikasi' : 'Open Installed Apps',
        isId
            ? 'AI dapat membuka aplikasi terinstall, halaman pengaturan Android, dan URL di browser.'
            : 'AI can open installed apps, Android system settings, and URLs in the browser.',
      ),
      'allow_background_launch' => (
        isId ? 'Izinkan Buka di Latar Belakang' : 'Allow Background Launch',
        isId
            ? 'Wajib aktif agar workflow dapat membuka aplikasi saat Meow Agent tidak terlihat. Memerlukan izin "Tampilkan di atas aplikasi lain".'
            : 'Required for workflows to open apps when Meow Agent is in the background. Needs "Display over other apps" permission.',
      ),
      _ => (key, ''),
    },
    'notification_intelligence' => switch (key) {
      'allow_read' => (
        isId ? 'Izinkan Baca Notifikasi' : 'Allow Read Notifications',
        isId
            ? 'Agen dapat membaca, merangkum, menandai penting, dan membuka aplikasi sumber notifikasi. Membutuhkan izin akses Notifikasi.'
            : 'Agent can read, summarize, classify importance, and open source apps of notifications. Requires Notification access permission.',
      ),
      'allow_reply' => (
        isId ? 'Izinkan Balas Notifikasi' : 'Allow Notification Replies',
        isId
            ? 'Agen dapat menyarankan dan mengirim balasan langsung ke notifikasi (WhatsApp, Telegram, dll).'
            : 'Agent can suggest and send direct replies to notifications (WhatsApp, Telegram, etc).',
      ),
      'persistent_notification' => (
        isId ? 'Tombol Cepat Papan Klip' : 'Clipboard Quick Action',
        isId
            ? 'Tampilkan notifikasi tetap berisi tombol untuk memproses teks papan klip kapan saja.'
            : 'Show an ongoing notification with a button to process clipboard text anytime.',
      ),
      _ => (key, ''),
    },
    'vm' => switch (key) {
      'allow_run_command' => (
        isId ? 'Jalankan Command' : 'Run Command',
        isId
            ? 'Agen dapat menjalankan perintah shell di dalam runtime yang sudah berjalan.'
            : 'Agent can run shell commands inside the running runtime.',
      ),
      _ => (key, ''),
    },
    'notes' => switch (key) {
      'allow_create' => (
        isId ? 'Izinkan Buat Note' : 'Allow Create Notes',
        isId
            ? 'Agen dapat membuat catatan baru.'
            : 'Agent can create new notes.',
      ),
      'allow_read' => (
        isId ? 'Izinkan Baca Note' : 'Allow Read Notes',
        isId
            ? 'Agen dapat membaca dan melihat daftar catatan.'
            : 'Agent can read and list notes.',
      ),
      'allow_search' => (
        isId ? 'Izinkan Cari Note' : 'Allow Search Notes',
        isId
            ? 'Agen dapat mencari catatan berdasarkan kata kunci.'
            : 'Agent can search notes by keyword.',
      ),
      _ => (key, ''),
    },
    'files' => switch (key) {
      'allow_create' => (
        isId ? 'Izinkan Buat File' : 'Allow Create Files',
        isId
            ? 'Agen dapat membuat file dan direktori baru di workspace.'
            : 'Agent can create new files and directories in workspace.',
      ),
      'allow_read' => (
        isId ? 'Izinkan Baca File' : 'Allow Read Files',
        isId
            ? 'Agen dapat membaca isi file dan melihat daftar direktori.'
            : 'Agent can read file contents and list directories.',
      ),
      'allow_write' => (
        isId ? 'Izinkan Tulis File' : 'Allow Write Files',
        isId
            ? 'Agen dapat mengedit dan menimpa file yang ada.'
            : 'Agent can edit and overwrite existing files.',
      ),
      'allow_delete' => (
        isId ? 'Izinkan Hapus File' : 'Allow Delete Files',
        isId
            ? 'Agen dapat menghapus file dan direktori. Perlu konfirmasi.'
            : 'Agent can delete files and directories. Requires confirmation.',
      ),
      'allow_organize' => (
        isId ? 'Izinkan Organisasi File' : 'Allow Organize Files',
        isId
            ? 'Agen dapat memindahkan dan mengganti nama file di workspace.'
            : 'Agent can move and rename files within workspace.',
      ),
      _ => (key, ''),
    },
    'calendar' => switch (key) {
      'allow_create' => (
        isId ? 'Izinkan Buat Event' : 'Allow Create Events',
        isId
            ? 'Agen dapat membuat event kalender baru.'
            : 'Agent can create new calendar events.',
      ),
      'allow_read' => (
        isId ? 'Izinkan Baca Event' : 'Allow Read Events',
        isId
            ? 'Agen dapat membaca dan melihat daftar event.'
            : 'Agent can read and list calendar events.',
      ),
      'allow_update' => (
        isId ? 'Izinkan Update Event' : 'Allow Update Events',
        isId
            ? 'Agen dapat mengubah event kalender yang ada.'
            : 'Agent can modify existing calendar events.',
      ),
      'allow_delete' => (
        isId ? 'Izinkan Hapus Event' : 'Allow Delete Events',
        isId
            ? 'Agen dapat menghapus event kalender. Perlu konfirmasi.'
            : 'Agent can delete calendar events. Requires confirmation.',
      ),
      _ => (key, ''),
    },
    'workflows' => switch (key) {
      'allow_create' => (
        isId ? 'Izinkan Buat Workflow' : 'Allow Create Workflows',
        isId
            ? 'Agen dapat membuat workflow terjadwal baru.'
            : 'Agent can create new scheduled workflows.',
      ),
      'allow_read' => (
        isId ? 'Izinkan Baca Workflow' : 'Allow Read Workflows',
        isId
            ? 'Agen dapat melihat daftar dan detail workflow.'
            : 'Agent can list and view workflow details.',
      ),
      'allow_update' => (
        isId ? 'Izinkan Update Workflow' : 'Allow Update Workflows',
        isId
            ? 'Agen dapat mengubah workflow yang ada.'
            : 'Agent can modify existing workflows.',
      ),
      'allow_delete' => (
        isId ? 'Izinkan Hapus Workflow' : 'Allow Delete Workflows',
        isId
            ? 'Agen dapat menghapus workflow. Perlu konfirmasi.'
            : 'Agent can delete workflows. Requires confirmation.',
      ),
      _ => (key, ''),
    },
    'web' => switch (key) {
      'allow_fetch' => (
        isId ? 'Izinkan Fetch URL' : 'Allow Fetch URLs',
        isId
            ? 'Agen dapat melakukan request HTTP ke URL publik.'
            : 'Agent can make HTTP requests to public URLs.',
      ),
      'allow_register' => (
        isId ? 'Izinkan Daftar API' : 'Allow Register APIs',
        isId
            ? 'Agen dapat menyimpan endpoint API baru ke store.'
            : 'Agent can save new API endpoints to the store.',
      ),
      'allow_call' => (
        isId ? 'Izinkan Panggil API' : 'Allow Call APIs',
        isId
            ? 'Agen dapat memanggil API yang tersimpan di store.'
            : 'Agent can call registered APIs from the store.',
      ),
      'allow_remove' => (
        isId ? 'Izinkan Hapus API' : 'Allow Remove APIs',
        isId
            ? 'Agen dapat menghapus API tersimpan. Perlu konfirmasi.'
            : 'Agent can delete registered APIs. Requires confirmation.',
      ),
      _ => (key, ''),
    },
    'communication' => switch (key) {
      'call_enabled' => (
        isId ? 'Telepon Otomatis' : 'Auto Phone Call',
        isId
            ? 'Langsung dial nomor telepon tanpa konfirmasi manual.'
            : 'Directly dial phone numbers without manual confirmation.',
      ),
      'sms_enabled' => (
        isId ? 'SMS Otomatis' : 'Auto SMS',
        isId
            ? 'Kirim SMS secara langsung tanpa buka aplikasi.'
            : 'Send SMS directly without opening the messaging app.',
      ),
      'contact_access' => (
        isId ? 'Akses Kontak' : 'Contact Access',
        isId
            ? 'Izinkan agen membaca buku kontak untuk resolve nama.'
            : 'Allow agent to read contacts to resolve names to numbers.',
      ),
      _ => (key, ''),
    },
    'super_power' => switch (key) {
      'overlay_bubble' => (
        isId ? 'Bubble Mengambang' : 'Floating Bubble',
        isId
            ? 'Tampilkan bubble AI mengambang di atas semua aplikasi untuk akses cepat.'
            : 'Show a floating AI bubble on top of all apps for quick access.',
      ),
      'app_agentic' => (
        'App Agentic',
        isId
            ? 'Izinkan agen membaca dan mengontrol layar aplikasi lain via Accessibility.'
            : 'Allow the agent to read and control other app screens via Accessibility.',
      ),
      'run_locked_device' => (
        isId
            ? 'Jalankan Saat Perangkat Terkunci'
            : 'Run While Device Is Locked',
        isId
            ? 'Gunakan Shizuku untuk membangunkan, membuka kunci, menjalankan automation, lalu mengunci lagi.'
            : 'Use Shizuku to wake, unlock, run automation, then lock the device again.',
      ),
      _ => (key, ''),
    },
    _ => (key, ''),
  };

  // --- Chat misc ---
  String get copied => isId ? 'Disalin' : 'Copied';
  String get copyTooltip => isId ? 'Salin' : 'Copy';
  String get closeTooltip => isId ? 'Tutup' : 'Close';

  // --- Workflow list ---
  String get workflowsTitle => isId ? 'Workflows' : 'Workflows';

  // --- Workflow runner status / error strings ---
  String workflowAgentNotFound(String agentId) =>
      isId ? 'Agent tidak ditemukan: $agentId' : 'Agent not found: $agentId';
  String workflowProviderNotFound(String providerId, String agentName) => isId
      ? 'Provider LLM "$providerId" tidak ditemukan untuk agent "$agentName".'
      : 'LLM provider "$providerId" not found for agent "$agentName".';
  String workflowTimeoutSeconds(int seconds) => isId
      ? 'Timeout: eksekusi melebihi $seconds detik.'
      : 'Timeout: execution exceeded $seconds.';
  String get workflowStepAgentNotFound => isId
      ? 'Agent tidak ditemukan untuk langkah ini.'
      : 'Agent not found for this step.';
  String workflowStepProviderNotFound(String agentName) => isId
      ? 'Provider tidak ditemukan untuk agent "$agentName".'
      : 'Provider not found for agent "$agentName".';
  String get workflowSensitiveFallbackTool =>
      isId ? 'aksi sensitif' : 'sensitive action';
  String workflowSensitiveBlocked(int step, String tool) => isId
      ? 'Langkah $step perlu izin aksi sensitif ($tool). '
            'Aktifkan "Izinkan aksi sensitif" di pengaturan workflow lalu jalankan ulang.'
      : 'Step $step needs sensitive permission ($tool). '
            'Enable "Allow sensitive actions" in workflow settings and re-run.';
  String get workflowErrorGeneric => 'Error';
  String workflowSingleSuccess(String title) => isId
      ? '✅ Workflow "$title" berhasil dijalankan.'
      : '✅ Workflow "$title" completed successfully.';
  String workflowSingleFailed(String title) => isId
      ? '❌ Workflow "$title" gagal dijalankan.'
      : '❌ Workflow "$title" failed to run.';
  String workflowChainedSuccess(String title, int steps) => isId
      ? '✅ Workflow "$title" selesai — $steps langkah.'
      : '✅ Workflow "$title" completed — $steps steps.';
  String workflowChainedFailed(String title, String overall) => isId
      ? '❌ Workflow "$title" — $overall'
      : '❌ Workflow "$title" — $overall';
  String workflowFailedStatus(String title, String error) => isId
      ? '❌ Workflow "$title" gagal: $error'
      : '❌ Workflow "$title" failed: $error';

  // --- Misc labels ---
  String get errorPrefix => 'Error';
  String errorWithMessage(String message) =>
      isId ? 'Error: $message' : 'Error: $message';
  String get runtimeDebugTitle => 'Runtime Debug';
  String get runningLabel => isId ? 'berjalan' : 'running';
}
