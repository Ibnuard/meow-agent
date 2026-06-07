import 'dart:convert';

import '../../../services/agent_runtime/prompt_constants.dart';
import '../../../services/workspace/workspace_file_service.dart';
import '../../chat/data/chat_history_service.dart';
import '../web/data/api_store_repository.dart';
import '../web/domain/http_executor.dart';

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

  String get placeholder => '@$key';

  String descriptionFor(String langCode) {
    final code = langCode.toLowerCase();
    if (code == 'id' || code.startsWith('id_')) return descriptionId;
    return descriptionEn;
  }
}

enum BuiltInCategory {
  time,
  identity,
  action,
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
      case BuiltInCategory.action:
        return isId ? 'Aksi' : 'Actions';
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
  BuiltInVariable(
    key: 'chat_session',
    descriptionId:
        'Sesi chat in-app dengan agent ini (target untuk "kirim ke chat")',
    descriptionEn:
        'In-app chat session with this agent (target for "send to chat")',
    category: BuiltInCategory.identity,
    exampleValue:
        '[chat session in-app dengan agent Mina Chan — gunakan chat.send]',
  ),
  BuiltInVariable(
    key: 'chat_history',
    descriptionId:
        'Cuplikan obrolan terakhir kamu dengan agent ini (max 20 pesan)',
    descriptionEn: 'Recent chat history with this agent (last 20 messages)',
    category: BuiltInCategory.identity,
    exampleValue: 'user: halo\nassistant: hai, ada yang bisa dibantu?',
  ),

  // ─── Actions ──────────────────────────────────────────────────────────────
  BuiltInVariable(
    key: 'push_nofif',
    descriptionId:
        'Kirim notifikasi push ke perangkat kamu',
    descriptionEn: 'Send a push notification to your device',
    category: BuiltInCategory.action,
    exampleValue: '[push notification target]',
  ),

  // ─── Multi-step ──────────────────────────────────────────────────────────
  // NOTE: @step1, @step2, ... @stepN are generated dynamically per workflow
  // by [stepResultVariables] (they depend on how many steps exist). Only the
  // step-agnostic `@prev` lives in this static catalog.
  BuiltInVariable(
    key: 'prev',
    descriptionId: 'Hasil dari langkah sebelumnya',
    descriptionEn: 'Output from the previous step',
    category: BuiltInCategory.step,
  ),

  // ─── Trigger: Notification ───────────────────────────────────────────────
  BuiltInVariable(
    key: 'notif',
    descriptionId: 'Notifikasi pemicu (pengirim + isi + app)',
    descriptionEn: 'Triggering notification (sender + body + app)',
    category: BuiltInCategory.triggerNotification,
  ),
  BuiltInVariable(
    key: 'notif_body',
    descriptionId: 'Isi pesan notifikasi',
    descriptionEn: 'Notification message body',
    category: BuiltInCategory.triggerNotification,
  ),
  BuiltInVariable(
    key: 'notif_sender',
    descriptionId: 'Pengirim + aplikasi (mis. Andi via WhatsApp)',
    descriptionEn: 'Sender + app (e.g. Andi via WhatsApp)',
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

/// Matches dynamic per-step result keys: `step1`, `step2`, ... `step42`.
final RegExp _stepResultKeyPattern = RegExp(r'^step(\d+)$');

/// True if [key] is a dynamic step-result reference (`step1`, `step2`, ...).
bool isStepResultKey(String key) => _stepResultKeyPattern.hasMatch(key);

/// The 1-based step number a `stepN` key points to, or null if not a step key.
int? stepResultNumber(String key) {
  final m = _stepResultKeyPattern.firstMatch(key);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// True if [key] is any recognized built-in: a static catalog entry OR a
/// dynamic `@stepN` reference OR an `@api:name` reference. The editor uses
/// this for highlighting, atomic-token deletion, and the undefined-variable
/// check so dynamic step variables and API references are treated as
/// first-class.
bool isKnownBuiltInKey(String key) =>
    kBuiltInVariableKeys.contains(key) ||
    isStepResultKey(key) ||
    key.startsWith('api:');

/// Build the dynamic step-result variables for a workflow with [stepCount]
/// steps. `@stepN` resolves to the output of step N (1-based).
///
/// Only steps whose output a LATER step could reference are emitted: the
/// FINAL step's output is never referenceable (nothing runs after it), so we
/// generate `@step1 .. @step{stepCount-1}`. Returns empty for < 2 steps.
List<BuiltInVariable> stepResultVariables(int stepCount) {
  if (stepCount < 2) return const [];
  return [
    for (var n = 1; n < stepCount; n++)
      BuiltInVariable(
        key: 'step$n',
        descriptionId: 'Hasil dari langkah $n',
        descriptionEn: 'Output from step $n',
        category: BuiltInCategory.step,
      ),
  ];
}

/// Resolver for built-in variables. Computes time/identity values once per
/// execution and merges trigger-derived vars on top so a notification's
/// `notif` always wins over user-stored custom vars.
class WorkflowBuiltInVars {
  WorkflowBuiltInVars._();

  /// Build the full variable map for a workflow execution.
  ///
  /// [agentName] is used both as `{{agent_name}}` and to fetch the user's
  /// SOUL.md identity fields.
  /// [agentId] is the running agent's id; used to resolve `{{chat_session}}`
  /// from recent chat history. Pass null if not available — `chat_session`
  /// will resolve to an empty string in that case.
  /// [triggerVars] are event-derived values like `{{notif}}`. They take
  /// precedence over computed values.
  /// [extra] is for runtime additions (e.g. {{prev}} during chained steps).
  static Future<Map<String, String>> resolve({
    required String agentName,
    required DateTime now,
    String? agentId,
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
    vars['chat_session'] = agentId == null
        ? '[chat session in-app dengan agent ini]'
        : renderChatSessionRef(agentName);
    vars['chat_history'] = agentId == null
        ? ''
        : await resolveChatHistory(agentId);

    // ── Action targets ─────────────────────────────────────────────────────
    vars['push_nofif'] =
        '[push notification target — use tool notification.create_local with '
        'args {title, body, style}; style defaults to normal]';

    // ── Trigger overrides ─────────────────────────────────────────────────
    vars.addAll(triggerVars);

    // ── Runtime extras (e.g. @prev, @step1..@stepN during chained steps) ──
    vars.addAll(extra);

    return vars;
  }

  /// Maximum characters of chat session to inline. Keeps prompt budget sane;
  /// the most recent messages are preserved when the cap is hit.
  static const int _chatSessionCharCap = 3000;

  /// Maximum messages pulled from the chat history.
  static const int _chatSessionMessageCap = 20;

  /// Short, target-friendly descriptor for the in-app chat session. This is
  /// what `{{chat_session}}` resolves to. Designed so prompts like
  /// "kirim ke {{chat_session}}" expand into something the agent recognizes
  /// as a delivery target (→ picks `chat.send`) rather than a content blob.
  ///
  /// Public so callers (e.g. workflow runner) can refresh `{{chat_session}}`
  /// per step when chained agents differ.
  static String renderChatSessionRef(String agentName) {
    return '[chat session in-app dengan agent "$agentName" — tujuan untuk '
        'tool chat.send / send-to-chat]';
  }

  /// Format the running agent's recent chat history as `role: content` lines.
  /// Empty string if there are no messages or loading fails.
  ///
  /// Public so callers (e.g. workflow runner) can refresh `{{chat_history}}`
  /// per step without re-resolving the entire built-in map.
  static Future<String> resolveChatHistory(String agentId) async {
    try {
      final svc = ChatHistoryService();
      final messages = await svc.loadLatest(
        agentId,
        limit: _chatSessionMessageCap,
      );
      if (messages.isEmpty) return '';
      final lines = messages
          .map((m) => '${m.role}: ${m.content.trim()}')
          .toList();
      var joined = lines.join('\n');
      if (joined.length > _chatSessionCharCap) {
        // Trim from the front so the most recent turns survive.
        joined = joined.substring(joined.length - _chatSessionCharCap);
        // Drop the leading partial line for cleanliness.
        final firstNewline = joined.indexOf('\n');
        if (firstNewline > 0 && firstNewline < joined.length - 1) {
          joined = joined.substring(firstNewline + 1);
        }
      }
      return joined;
    } catch (_) {
      return '';
    }
  }

  /// Substitute every `@key` (and legacy `{{key}}`) placeholder in [prompt]
  /// with values from [vars].
  ///
  /// `@key` is matched with a left-side word boundary so emails like
  /// `foo@bar.com` don't get rewritten. The right side stops at the first
  /// non-word character.
  ///
  /// Unknown placeholders are left as-is so the agent can still see them and
  /// the user notices the typo.
  static String substitute(String prompt, Map<String, String> vars) {
    var resolved = prompt;
    for (final entry in vars.entries) {
      final escaped = RegExp.escape(entry.key);
      // Legacy {{key}} — still supported for older workflows.
      resolved = resolved.replaceAll('{{${entry.key}}}', entry.value);
      // New @key — word-bounded, won't touch emails or @@chains.
      final re = RegExp('(?<![\\w@])@$escaped\\b');
      resolved = resolved.replaceAllMapped(re, (_) => entry.value);
    }
    return resolved;
  }

  /// Resolve all `@api:Name` references in [prompt] by executing the stored
  /// API and replacing the token with the HTTP response body.
  ///
  /// API names are matched case-insensitively with spaces normalized to
  /// underscores. If an API is not found or execution fails, the token is
  /// replaced with an error message so the agent can react gracefully.
  static Future<String> resolveApiReferences(String prompt) async {
    // Match @api:Name tokens (name is word chars including underscores).
    final pattern = RegExp(r'(?<![\w@])@api:(\w+)');
    final matches = pattern.allMatches(prompt).toList();
    if (matches.isEmpty) return prompt;

    final apis = await ApiStoreRepository.instance.list();
    var resolved = prompt;
    final resolvedNames = <String>[];

    // Process in reverse so indices stay valid after replacements.
    for (final match in matches.reversed) {
      final rawName = match.group(1) ?? '';
      final searchName = rawName.replaceAll('_', ' ').toLowerCase();

      // Find API by name (case-insensitive, underscore = space).
      final api = apis.where((a) {
        return a.name.toLowerCase() == searchName ||
            a.name.replaceAll(' ', '_').toLowerCase() == rawName.toLowerCase();
      }).firstOrNull;

      String replacement;
      if (api == null) {
        replacement = '[API "$rawName" not found in store]';
      } else {
        try {
          final executor = HttpExecutor();
          final result = await executor.executeFromConfig(config: api);
          if (result.isSuccess) {
            final raw = result.body is String
                ? result.body as String
                : jsonEncode(result.body);
            replacement = _wrapApiResponse(api.name, api.method, raw);
            resolvedNames.add(api.name);
          } else {
            replacement =
                '[API "${api.name}" returned ${result.statusCode}: ${result.error ?? result.body}]';
          }
        } catch (e) {
          replacement = '[API "${api.name}" failed: $e]';
        }
      }

      resolved = resolved.replaceRange(match.start, match.end, replacement);
    }

    // Prepend an instruction header so the agent treats the embedded
    // API_RESPONSE blocks as ground truth, not as missing context.
    if (resolvedNames.isNotEmpty) {
      resolved =
          PromptConstants.workflowApiContext(resolvedNames) + resolved;
    }

    return resolved;
  }

  /// Maximum size of an inlined API response body. Anything larger is
  /// truncated with a clear marker so the prompt budget stays sane.
  static const int _apiResponseCharCap = 6000;

  /// Wrap a fetched API body so the agent treats it as a data payload
  /// (not free-form text). The fenced block + metadata header makes
  /// downstream tool selection ("save this to a note") much more reliable.
  static String _wrapApiResponse(String apiName, String method, String body) {
    final trimmed = body.trim();
    final truncated = trimmed.length > _apiResponseCharCap
        ? '${trimmed.substring(0, _apiResponseCharCap)}\n...[truncated, original ${trimmed.length} chars]'
        : trimmed;
    final lang = _detectBodyLang(truncated);
    return '\n[API_RESPONSE name="$apiName" method="$method" bytes=${trimmed.length}]\n'
        '```$lang\n$truncated\n```\n[/API_RESPONSE]\n';
  }

  /// Heuristic: pick a markdown fence label so the agent treats JSON/XML
  /// payloads as structured data rather than prose.
  static String _detectBodyLang(String body) {
    final t = body.trimLeft();
    if (t.startsWith('{') || t.startsWith('[')) return 'json';
    if (t.startsWith('<')) return 'xml';
    return 'text';
  }

  /// Convert any legacy `{{key}}` placeholder for KNOWN built-ins into the
  /// new `@key` form. Unknown keys are left as-is so users can still see
  /// their typos.
  ///
  /// Idempotent: running on already-migrated text is a no-op.
  static String migrateLegacyPlaceholders(String text) {
    if (text.isEmpty) return text;
    var out = text;
    for (final key in kBuiltInVariableKeys) {
      out = out.replaceAll('{{$key}}', '@$key');
    }
    return out;
  }

  // ─── Time formatting helpers ──────────────────────────────────────────

  static String _fmtDate(DateTime d) =>
      '${d.year}-${_pad(d.month)}-${_pad(d.day)}';

  static String _fmtTime(DateTime d) => '${_pad(d.hour)}:${_pad(d.minute)}';

  static String _pad(int n) => n.toString().padLeft(2, '0');

  static const _idMonths = [
    'Januari',
    'Februari',
    'Maret',
    'April',
    'Mei',
    'Juni',
    'Juli',
    'Agustus',
    'September',
    'Oktober',
    'November',
    'Desember',
  ];
  static const _enMonths = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  static const _idDays = [
    'Senin',
    'Selasa',
    'Rabu',
    'Kamis',
    'Jumat',
    'Sabtu',
    'Minggu',
  ];
  static const _enDays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
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
  factory _UserIdentity.empty() => const _UserIdentity(name: '', nickname: '');
  final String name;
  final String nickname;
}
