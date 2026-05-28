import 'pending_action.dart';

/// Selects a smaller tool surface for a runtime turn.
///
/// This is an accuracy-preserving fast filter: if intent confidence is low,
/// callers should use the full catalog.
class ToolCatalogSelection {
  const ToolCatalogSelection({
    required this.toolNames,
    required this.groups,
    required this.confidence,
    required this.reason,
  });

  final Set<String> toolNames;
  final Set<String> groups;
  final double confidence;
  final String reason;

  bool get isHighConfidence => confidence >= 0.75;
}

class ToolCatalog {
  ToolCatalog._();

  static const Map<String, Set<String>> groups = {
    'app': {
      'app.resolve',
      'app.open',
      'app.list_installed',
      'settings.open',
      'intent.open_url',
    },
    'clipboard': {'clipboard.read', 'clipboard.write'},
    'device': {
      'device.battery',
      'device.network',
      'device.storage',
      'device.time',
      'device.locale',
      'device.summary',
      'device.foreground_app',
      'device.usage_stats',
      'device.charging',
      'device.dnd',
      'device.bluetooth',
      'device.dnd.set',
      'device.wifi.reconnect',
      'device.bluetooth.set',
      'device.wifi',
      'device.cellular',
    },
    'notification': {
      'notification.status',
      'notification.read_recent',
      'notification.summarize',
      'notification.classify',
      'notification.reply_suggestion',
      'notification.open_app',
      'notification.create_local',
    },
    'notes': {
      'notes.create',
      'notes.list_recent',
      'notes.read',
      'notes.search',
      'notes.update',
      'notes.delete',
      'notes.export',
      'notes.pin',
      'notes.unpin',
      'notes.archive',
      'notes.unarchive',
      'notes.append',
    },
    'files': {
      'files.create',
      'files.read',
      'files.write',
      'files.delete',
      'files.list',
      'files.move',
      'files.mkdir',
      'files.copy',
      'files.append',
      'files.metadata',
      'files.search',
      'files.tree',
    },
    'calendar': {
      'calendar.create',
      'calendar.today',
      'calendar.list',
      'calendar.read',
      'calendar.update',
      'calendar.delete',
      'calendar.upcoming',
      'calendar.conflicts',
      'calendar.free_slot',
      'calendar.link_note',
    },
    'workflow': {
      'workflow.create',
      'workflow.create_from_template',
      'workflow.list_templates',
      'workflow.list',
      'workflow.read',
      'workflow.update',
      'workflow.delete',
      'workflow.toggle',
    },
    'system': {
      'system.self',
      'system.workspace.schema',
      'system.workspace.read',
      'system.profile.update',
      'system.memory.append',
      'system.agents.list',
      'system.agents.create',
      'system.agents.delete',
      'system.agents.update',
      'system.providers.list',
      'system.modules.list',
      'system.modules.toggle',
      'system.tools.list',
      'system.export_all',
      'system.import',
    },
    'chat': {
      'chat.send',
    },
  };

  static ToolCatalogSelection select({
    required String userMessage,
    PendingAction? pendingAction,
    bool isWorkflowAutoExecute = false,
  }) {
    if (isWorkflowAutoExecute) {
      return ToolCatalogSelection(
        toolNames: _allTools(),
        groups: groups.keys.toSet(),
        confidence: 0,
        reason: 'workflow uses broad catalog for accuracy',
      );
    }

    if (pendingAction != null) {
      return ToolCatalogSelection(
        toolNames: {
          pendingAction.toolName,
          ...groups['files']!,
          ...groups['system']!,
        },
        groups: {'pending', 'files', 'system'},
        confidence: 0.9,
        reason: 'pending action follow-up',
      );
    }

    final text = _normalize(userMessage);
    final hasUrl = _hasUrl(text);
    final groupStrength = <String, int>{};

    void scoreGroup(String group, int strength) {
      if (strength > 0) {
        groupStrength[group] = (groupStrength[group] ?? 0) + strength;
      }
    }

    scoreGroup('app', _matchStrength(text, _appOpenWords) + (hasUrl ? 3 : 0));
    scoreGroup('clipboard', _matchStrength(text, _clipboardWords));
    scoreGroup('notes', _matchStrength(text, _noteWords));
    scoreGroup('calendar', _matchStrength(text, _calendarWords));
    scoreGroup('files', _matchStrength(text, _fileWords));
    scoreGroup('device', _matchStrength(text, _deviceWords));
    scoreGroup('notification', _matchStrength(text, _notificationWords));
    scoreGroup('workflow', _matchStrength(text, _workflowWords));
    scoreGroup('system', _matchStrength(text, _systemWords));

    // Memory/identity hits route to core system workspace tools.
    final memoryStrength = _matchStrength(text, _memoryWords);
    if (memoryStrength > 0) {
      scoreGroup('system', memoryStrength);
    }

    if (groupStrength.isEmpty) {
      return ToolCatalogSelection(
        toolNames: _allTools(),
        groups: groups.keys.toSet(),
        confidence: 0,
        reason: 'no confident local intent match; full catalog fallback',
      );
    }

    final selectedGroups = groupStrength.keys.toSet();
    final groupCount = selectedGroups.length;
    final totalStrength = groupStrength.values.fold<int>(0, (a, b) => a + b);

    // Confidence model based on match quality (not just group count):
    //   strength 3 = multi-word phrase ("buka whatsapp", "remind me")
    //   strength 2 = longer single word ("spotify", "battery", "remember")
    //   strength 1 = short single word ("wa", "yt", "ig")
    double confidence;
    if (groupCount == 1 && totalStrength >= 3) {
      confidence = 0.85; // strong single-intent signal
    } else if (groupCount == 1 && totalStrength >= 2) {
      confidence = 0.78; // solid single-intent signal
    } else if (groupCount == 1) {
      confidence = 0.55; // single short word — ambiguous
    } else if (groupCount == 2 && totalStrength >= 4) {
      confidence = 0.72; // two strong signals
    } else if (groupCount == 2) {
      confidence = 0.60; // two weak signals
    } else {
      confidence = 0.50; // 3+ groups — too broad to narrow safely
    }

    // Low confidence → full catalog. The narrow filter would be unreliable.
    if (confidence < 0.60) {
      return ToolCatalogSelection(
        toolNames: _allTools(),
        groups: groups.keys.toSet(),
        confidence: confidence,
        reason:
            'weak match (strength $totalStrength across $groupCount groups); '
            'falling back to full catalog',
      );
    }

    final toolNames = <String>{};
    for (final group in selectedGroups) {
      toolNames.addAll(groups[group]!);
    }

    // System introspection often pivots into files (config dumps, agent specs).
    if (selectedGroups.contains('system')) {
      toolNames.addAll(groups['files']!);
    }

    return ToolCatalogSelection(
      toolNames: toolNames,
      groups: selectedGroups,
      confidence: confidence,
      reason:
          'matched groups: ${selectedGroups.join(', ')} '
          '(strength $totalStrength)',
    );
  }

  static Set<String> _allTools() =>
      groups.values.expand((tools) => tools).toSet();

  static String _normalize(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s.:/_-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Returns the quality score of the best-matched term, or 0 if no match.
  ///
  /// Scoring:
  ///   3 — multi-word phrase ("buka whatsapp", "remind me", "my name is")
  ///   2 — long single word, length > 3 ("spotify", "battery", "remember")
  ///   1 — short single word, length ≤ 3 ("wa", "yt", "ig", "fb")
  ///
  /// Short single words must be a standalone token (no substring match) to
  /// avoid false positives like "wa" matching inside "wajah".
  static int _matchStrength(String text, Set<String> terms) {
    final words = text.split(' ').where((w) => w.isNotEmpty).toSet();
    var best = 0;
    for (final term in terms) {
      final isPhrase = term.contains(' ');
      if (isPhrase) {
        if (text.contains(term)) {
          if (3 > best) best = 3;
        }
        continue;
      }
      if (term.length <= 3) {
        // Short tokens must match whole-word.
        if (words.contains(term)) {
          if (1 > best) best = 1;
        }
        continue;
      }
      // Longer single words can match as substrings ("battery" inside "battery%").
      if (text.contains(term)) {
        if (2 > best) best = 2;
      }
    }
    return best;
  }

  static bool _hasUrl(String text) {
    return text.contains('http://') ||
        text.contains('https://') ||
        RegExp(r'\b[a-z0-9-]+\.[a-z]{2,}\b').hasMatch(text);
  }

  static const _appOpenWords = {
    // Verbs (ID + EN)
    'buka',
    'open',
    'launch',
    'jalankan',
    'start',
    'go to',
    // Common apps (global)
    'whatsapp',
    'wa',
    'youtube',
    'yt',
    'instagram',
    'ig',
    'telegram',
    'tg',
    'twitter',
    'x app',
    'facebook',
    'fb',
    'tiktok',
    'spotify',
    'gmail',
    'maps',
    'chrome',
    'firefox',
    'safari',
    'browser',
    // Settings
    'settings',
    'pengaturan',
    'preferences',
  };

  static const _clipboardWords = {
    'clipboard',
    'papan klip',
    'copy',
    'copied',
    'salin',
    'tersalin',
    'paste',
    'pasted',
    'tempel',
    'tempelin',
  };

  static const _noteWords = {
    // ID
    'catat',
    'catatan',
    'buat note',
    'buat catatan',
    'simpan catatan',
    // EN
    'note',
    'notes',
    'take note',
    'take a note',
    'write down',
    'jot down',
    'jot',
    'memo',
    'save note',
    'create note',
    'new note',
  };

  static const _calendarWords = {
    // ID
    'jadwal',
    'jadwalkan',
    'kalender',
    'ingatkan',
    'ingetin',
    'janji',
    'pasang reminder',
    // EN
    'calendar',
    'schedule',
    'scheduling',
    'reminder',
    'remind me',
    'set reminder',
    'set a reminder',
    'meeting',
    'event',
    'appointment',
    'agenda',
  };

  static const _fileWords = {
    // ID
    'file',
    'folder',
    'baca file',
    'tulis file',
    'edit file',
    'simpan file',
    'buat file',
    'hapus file',
    'workspace',
    'profil',
    'profile',
    'identitas',
    'direktori',
    'dokumen',
    // EN
    'read file',
    'write file',
    'save file',
    'create file',
    'delete file',
    'document',
    'directory',
    // System files (always relevant for memory/identity ops)
    'soul.md',
    'memory.md',
    'skills.md',
    'heartbeat.md',
    'workspace schema',
    'system md',
    'agent md',
  };

  static const _deviceWords = {
    // Battery / power
    'battery',
    'baterai',
    'charging',
    'ngecas',
    'mengisi daya',
    'charger',
    // Network
    'wifi',
    'wi-fi',
    'network',
    'jaringan',
    'signal',
    'sinyal',
    'data',
    'kuota',
    'cellular',
    'mobile data',
    // Storage
    'storage',
    'penyimpanan',
    'free space',
    'ruang kosong',
    // Connectivity
    'bluetooth',
    'airplane mode',
    'mode pesawat',
    // Sound / focus
    'dnd',
    'do not disturb',
    'jangan ganggu',
    'silent',
    'mute',
    'senyap',
    'bisukan',
    // Generic
    'device',
    'perangkat',
  };

  static const _notificationWords = {
    'notification',
    'notifications',
    'notifikasi',
    'notif',
    'notifs',
    'ringkas notifikasi',
    'summarize notification',
    'summarize notifs',
    'recent notif',
    'latest notif',
  };

  static const _workflowWords = {
    // ID
    'jadwalkan tugas',
    'otomatisasi',
    'otomatis',
    'tugas berkala',
    'setiap hari',
    'setiap jam',
    // EN
    'workflow',
    'workflows',
    'automation',
    'automate',
    'scheduled task',
    'recurring task',
    'recurring',
    'cron',
    'background task',
    'every day',
    'every hour',
    'daily',
    'hourly',
    'weekly',
  };

  static const _systemWords = {
    // Entities
    'agent',
    'agen',
    'provider',
    'penyedia',
    'model',
    'llm',
    'module',
    'modul',
    'tool',
    'tools',
    'workspace',
    'soul',
    'memory',
    // ID phrases
    'kamu pakai',
    'kamu gunakan',
    'kamu pake',
    'apa yang kamu pakai',
    'buat agent',
    'buat agen',
    'tambah agent',
    'hapus agent',
    'daftar agen',
    'daftar modul',
    'daftar provider',
    'daftar tool',
    'ada berapa modul',
    'ada berapa module',
    'ada berapa agent',
    'workspace kamu',
    'file agent',
    'system md',
    'agent md',
    // EN phrases
    'your model',
    'which model',
    'what model',
    'create agent',
    'add agent',
    'delete agent',
    'list agents',
    'list modules',
    'list providers',
    'list tools',
    'workspace path',
    'workspace files',
  };

  static const _memoryWords = {
    // ID — identity
    'nama saya',
    'nama aku',
    'nama gue',
    'nama gw',
    'panggil saya',
    'panggil aku',
    'panggil gue',
    // ID — preferences / memory
    'ingat',
    'inget',
    'simpan bahwa',
    'simpan kalau',
    'preferensi',
    'aku suka',
    'saya suka',
    'favorit saya',
    // EN — identity
    'my name is',
    'call me',
    'im called',
    'i am called',
    // EN — preferences / memory
    'remember',
    'remember that',
    'remember this',
    'save that',
    'save this',
    'i prefer',
    'i like',
    'i love',
    'my favorite',
    'note that i',
    'preference',
    'fyi i',
  };
}
