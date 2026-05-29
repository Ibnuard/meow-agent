import '../../../services/workspace/workspace_file_service.dart';

/// Catalog entry describing a single built-in variable so the editor UI
/// can render it (label + description) and let users tap-to-insert.
class BuiltInVariable {
  const BuiltInVariable({
    required this.key,
    required this.descriptionId,
    required this.descriptionEn,
    required this.category,
    this.exampleValue,
  });

  final String key;
  final String descriptionId;
  final String descriptionEn;
  final BuiltInCategory category;
  final String? exampleValue;

  String get placeholder => '{{$key}}';

  String descriptionFor(String langCode) {
    final code = langCode.toLowerCase();
    if (code == 'id' || code.startsWith('id_')) return descriptionId;
    return descriptionEn;
  }
}

enum BuiltInCategory {
  time,
  identity,
  triggerNotification,
  triggerAppOpen,
  triggerBattery,
  step,
}

extension BuiltInCategoryX on BuiltInCategory {
  String labelFor(String langCode) {
    final isId = langCode.toLowerCase().startsWith('id');
    switch (this) {
      case BuiltInCategory.time:
        return isId ? 'Waktu & Tanggal' : 'Time & Date';
      case BuiltInCategory.identity:
        return isId ? 'Identitas' : 'Identity';
      case BuiltInCategory.triggerNotification:
        return isId ? 'Pemicu: Notifikasi' : 'Trigger: Notification';
      case BuiltInCategory.triggerAppOpen:
        return isId ? 'Pemicu: Buka Aplikasi' : 'Trigger: App Opened';
      case BuiltInCategory.triggerBattery:
        return isId ? 'Pemicu: Baterai' : 'Trigger: Battery';
      case BuiltInCategory.step:
        return isId ? 'Multi-Langkah' : 'Multi-Step';
    }
  }
}

/// All built-in variables this workflow runner knows how to resolve.
/// Editor uses this to render the picker; runner uses it via
/// [WorkflowBuiltInVars.resolve] to expand values at execution time.
const List<BuiltInVariable> kWorkflowBuiltInVariables = [
  // ─── Time & Date ─────────────────────────────────────────────────────────
  BuiltInVariable(
    key: 'date',
    descriptionId: 'Tanggal hari ini (YYYY-MM-DD)',
    descriptionEn: "Today's date (YYYY-MM-DD)",
    category: BuiltInCategory.time,
    exampleValue: '2026-05-29',
  ),
  BuiltInVariable(
    key: 'time',
    descriptionId: 'Jam saat ini (HH:mm)',
    descriptionEn: 'Current time (HH:mm)',
    category: BuiltInCategory.time,
    exampleValue: '14:30',
  ),
  BuiltInVariable(
    key: 'datetime',
    descriptionId: 'Tanggal & jam (YYYY-MM-DD HH:mm)',
    descriptionEn: 'Date & time (YYYY-MM-DD HH:mm)',
    category: BuiltInCategory.time,
    exampleValue: '2026-05-29 14:30',
  ),
  BuiltInVariable(
    key: 'day_name',
    descriptionId: 'Nama hari (Senin, Selasa, ...)',
    descriptionEn: 'Day of week (Monday, Tuesday, ...)',
    category: BuiltInCategory.time,
    exampleValue: 'Jumat',
  ),
  BuiltInVariable(
    key: 'date_long',
    descriptionId: 'Tanggal panjang (29 Mei 2026)',
    descriptionEn: 'Long date (29 May 2026)',
    category: BuiltInCategory.time,
    exampleValue: '29 Mei 2026',
  ),
  BuiltInVariable(
    key: 'month_name',
    descriptionId: 'Nama bulan (Mei, Juni, ...)',
    descriptionEn: 'Month name (May, June, ...)',
    category: BuiltInCategory.time,
    exampleValue: 'Mei',
  ),
  BuiltInVariable(
    key: 'year',
    descriptionId: 'Tahun (YYYY)',
    descriptionEn: 'Year (YYYY)',
    category: BuiltInCategory.time,
    exampleValue: '2026',
  ),
  BuiltInVariable(
    key: 'iso_timestamp',
    descriptionId: 'Timestamp ISO 8601 lengkap',
    descriptionEn: 'Full ISO 8601 timestamp',
    category: BuiltInCategory.time,
    exampleValue: '2026-05-29T14:30:00',
  ),

  // ─── Identity ────────────────────────────────────────────────────────────
  BuiltInVariable(
    key: 'agent_name',
    descriptionId: 'Nama agent yang menjalankan workflow',
    descriptionEn: 'Name of the agent running this workflow',
    category: BuiltInCategory.identity,
    exampleValue: 'Mina Chan',
  ),
  BuiltInVariable(
    key: 'user_name',
    descriptionId: 'Nama kamu (dari profil agent)',
    descriptionEn: 'Your name (from the agent profile)',
    category: BuiltInCategory.identity,
    exampleValue: 'Ibnu',
  ),
  BuiltInVariable(
    key: 'user_nickname',
    descriptionId: 'Panggilan kamu (dari profil agent)',
    descriptionEn: 'Your nickname (from the agent profile)',
    category: BuiltInCategory.identity,
  ),

  // ─── Multi-step ──────────────────────────────────────────────────────────
  BuiltInVariable(
    key: 'prev',
    descriptionId: 'Hasil dari langkah sebelumnya',
    descriptionEn: 'Output from the previous step',
    category: BuiltInCategory.step,
  ),
  BuiltInVariable(
    key: 'step_index',
    descriptionId: 'Nomor urut langkah saat ini (0, 1, 2 ...)',
    descriptionEn: 'Current step index (0, 1, 2 ...)',
    category: BuiltInCategory.step,
  ),

  // ─── Trigger: Notification ───────────────────────────────────────────────
  BuiltInVariable(
    key: 'notif',
    descriptionId: 'Notifikasi pemicu (judul + isi)',
    descriptionEn: 'Triggering notification (title + body)',
    category: BuiltInCategory.triggerNotification,
  ),
  BuiltInVariable(
    key: 'notif_title',
    descriptionId: 'Judul notifikasi',
    descriptionEn: 'Notification title',
    category: BuiltInCategory.triggerNotification,
  ),
  BuiltInVariable(
    key: 'notif_body',
    descriptionId: 'Isi notifikasi',
    descriptionEn: 'Notification body',
    category: BuiltInCategory.triggerNotification,
  ),
  BuiltInVariable(
    key: 'notif_app',
    descriptionId: 'Nama aplikasi pengirim',
    descriptionEn: 'Sender app name',
    category: BuiltInCategory.triggerNotification,
  ),
  BuiltInVariable(
    key: 'notif_keyword',
    descriptionId: 'Kata kunci yang cocok',
    descriptionEn: 'Matched keyword',
    category: BuiltInCategory.triggerNotification,
  ),

  // ─── Trigger: App Opened ─────────────────────────────────────────────────
  BuiltInVariable(
    key: 'app_package',
    descriptionId: 'Package aplikasi yang dibuka',
    descriptionEn: 'Opened app package id',
    category: BuiltInCategory.triggerAppOpen,
  ),

  // ─── Trigger: Battery ────────────────────────────────────────────────────
  BuiltInVariable(
    key: 'battery_level',
    descriptionId: 'Level baterai saat trigger (0-100)',
    descriptionEn: 'Battery level at trigger time (0-100)',
    category: BuiltInCategory.triggerBattery,
  ),
];

/// Static set of reserved keys — used by editor to skip these from the
/// "undefined variable" warning.
final Set<String> kBuiltInVariableKeys = {
  for (final v in kWorkflowBuiltInVariables) v.key,
};

/// Resolver for built-in variables. Computes time/identity values once per
/// execution and merges trigger-derived vars on top so a notification's
/// `notif` always wins over user-stored custom vars.
class WorkflowBuiltInVars {
  WorkflowBuiltInVars._();

  /// Build the full variable map for a workflow execution.
  ///
  /// [agentName] is used both as `{{agent_name}}` and to fetch the user's
  /// SOUL.md identity fields.
  /// [triggerVars] are event-derived values like `{{notif}}`. They take
  /// precedence over computed values.
  /// [extra] is for runtime additions (e.g. {{prev}} during chained steps).
  static Future<Map<String, String>> resolve({
    required String agentName,
    required DateTime now,
    String langCode = 'id',
    Map<String, String> triggerVars = const {},
    Map<String, String> extra = const {},
  }) async {
    final vars = <String, String>{};

    // ── Time / Date ────────────────────────────────────────────────────────
    vars['date'] = _fmtDate(now);
    vars['time'] = _fmtTime(now);
    vars['datetime'] = '${_fmtDate(now)} ${_fmtTime(now)}';
    vars['day_name'] = _dayName(now.weekday, langCode);
    vars['date_long'] = _dateLong(now, langCode);
    vars['month_name'] = _monthName(now.month, langCode);
    vars['year'] = '${now.year}';
    vars['iso_timestamp'] = now.toIso8601String();

    // ── Identity ──────────────────────────────────────────────────────────
    vars['agent_name'] = agentName;
    final identity = await _readUserIdentity(agentName);
    vars['user_name'] = identity.name;
    vars['user_nickname'] = identity.nickname;

    // ── Trigger overrides ─────────────────────────────────────────────────
    vars.addAll(triggerVars);

    // ── Runtime extras (e.g. {{prev}}, {{step_index}}) ───────────────────
    vars.addAll(extra);

    return vars;
  }

  /// Substitute every `{{key}}` placeholder in [prompt] with values from
  /// [vars]. Unknown placeholders are left as-is so the agent can still see
  /// them and the user notices the typo.
  static String substitute(String prompt, Map<String, String> vars) {
    var resolved = prompt;
    for (final entry in vars.entries) {
      resolved = resolved.replaceAll('{{${entry.key}}}', entry.value);
    }
    return resolved;
  }

  // ─── Time formatting helpers ──────────────────────────────────────────

  static String _fmtDate(DateTime d) =>
      '${d.year}-${_pad(d.month)}-${_pad(d.day)}';

  static String _fmtTime(DateTime d) => '${_pad(d.hour)}:${_pad(d.minute)}';

  static String _pad(int n) => n.toString().padLeft(2, '0');

  static const _idMonths = [
    'Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni',
    'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember',
  ];
  static const _enMonths = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  static const _idDays = [
    'Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu',
  ];
  static const _enDays = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
  ];

  static String _monthName(int month, String langCode) {
    final isId = langCode.toLowerCase().startsWith('id');
    final list = isId ? _idMonths : _enMonths;
    if (month < 1 || month > 12) return '';
    return list[month - 1];
  }

  static String _dayName(int weekday, String langCode) {
    final isId = langCode.toLowerCase().startsWith('id');
    final list = isId ? _idDays : _enDays;
    if (weekday < 1 || weekday > 7) return '';
    return list[weekday - 1];
  }

  static String _dateLong(DateTime d, String langCode) {
    return '${d.day} ${_monthName(d.month, langCode)} ${d.year}';
  }

  // ─── User identity from SOUL.md ───────────────────────────────────────

  static Future<_UserIdentity> _readUserIdentity(String agentName) async {
    try {
      final soul = await WorkspaceFileService.readFile(agentName, 'SOUL.md');
      if (soul.isEmpty) return _UserIdentity.empty();
      // Find the User Identity section.
      final sectionMatch = RegExp(
        r'##\s*User Identity[^\n]*\n([\s\S]*?)(?=\n##\s|---\s*\n|$)',
        caseSensitive: false,
      ).firstMatch(soul);
      if (sectionMatch == null) return _UserIdentity.empty();
      final body = sectionMatch.group(1) ?? '';
      return _UserIdentity(
        name: _extractField(body, 'Name'),
        nickname: _extractField(body, 'Nickname'),
      );
    } catch (_) {
      return _UserIdentity.empty();
    }
  }

  static String _extractField(String body, String fieldName) {
    final m = RegExp(
      '^$fieldName:[ \\t]*(.*?)[ \\t]*\$',
      multiLine: true,
    ).firstMatch(body);
    if (m == null) return '';
    final v = (m.group(1) ?? '').trim();
    // Strip placeholders like [Your Name].
    if (RegExp(r'^\[.*\]$').hasMatch(v)) return '';
    return v;
  }
}

class _UserIdentity {
  const _UserIdentity({required this.name, required this.nickname});
  factory _UserIdentity.empty() =>
      const _UserIdentity(name: '', nickname: '');
  final String name;
  final String nickname;
}
