import 'package:flutter/services.dart';

import '../../features/modules/device_context/device_context_repository.dart';
import '../../features/modules/device_context/device_context_service.dart';
import '../../features/modules/data/module_repository.dart';
import '../../features/modules/calendar/calendar_tools.dart';
import '../../features/modules/files/files_tools.dart';
import '../../features/modules/notes/notes_tools.dart';
import '../../features/modules/notification_intelligence/notification_repository.dart';
import '../../features/modules/notification_intelligence/notification_service.dart';
import 'app_alias_resolver.dart';
import 'runtime_models.dart';

/// Routes tool calls to their implementations.
/// Validates tool existence and enforces risk/confirmation rules.
class ToolRouter {
  ToolRouter({this.agentName = ''});

  /// The current agent name — used by workspace-scoped tools (files module).
  String agentName;

  /// Registry of all known tools with their definitions.
  final Map<String, ToolDefinition> _registry = {
    'clipboard.read': const ToolDefinition(
      name: 'clipboard.read',
      description: 'Read current clipboard text.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'clipboard.write': const ToolDefinition(
      name: 'clipboard.write',
      description: 'Write text to clipboard.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'text': 'string'},
    ),
    'app.resolve': const ToolDefinition(
      name: 'app.resolve',
      description: 'Resolve a friendly app name (e.g. "wa", "toko ijo", "youtube") to a package name. ALWAYS call this first before app.open.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'query': 'string (friendly name to resolve)'},
    ),
    'app.open': const ToolDefinition(
      name: 'app.open',
      description: 'Open an installed app by exact package name. Use app.resolve first to get the package name.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'package': 'string (exact package name from app.resolve)'},
    ),
    'app.list_installed': const ToolDefinition(
      name: 'app.list_installed',
      description: 'List all installed launchable apps.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'settings.open': const ToolDefinition(
      name: 'settings.open',
      description: 'Open Android system settings.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'action': 'string'},
    ),
    'intent.open_url': const ToolDefinition(
      name: 'intent.open_url',
      description: 'Open a URL in the default browser.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'url': 'string'},
    ),
    // ── Device Context ──────────────────────────────────────────────────
    'device.battery': const ToolDefinition(
      name: 'device.battery',
      description: 'Read current battery level and charging status.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.network': const ToolDefinition(
      name: 'device.network',
      description: 'Read current network connection type and status.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.storage': const ToolDefinition(
      name: 'device.storage',
      description: 'Read current device storage usage.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.time': const ToolDefinition(
      name: 'device.time',
      description: 'Read current local device time and timezone.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.locale': const ToolDefinition(
      name: 'device.locale',
      description: 'Read device language and locale.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.summary': const ToolDefinition(
      name: 'device.summary',
      description: 'Read a summary of battery, network, storage, time, and locale.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.foreground_app': const ToolDefinition(
      name: 'device.foreground_app',
      description: 'Read the app that is CURRENTLY in the foreground RIGHT NOW. '
          'This does NOT provide usage history, screen time, or statistics. '
          'If asked about past usage or most-used apps, say you cannot access that data.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.usage_stats': const ToolDefinition(
      name: 'device.usage_stats',
      description: 'Read real app usage statistics for the past N days (default 7). '
          'Returns top 10 user-facing apps sorted by total usage time in minutes. '
          'Use this when asked about most-used apps, screen time, or app usage history. '
          'Args: days (int, optional, default 7).',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'days': 'int (optional, default 7)'},
    ),
    'device.charging': const ToolDefinition(
      name: 'device.charging',
      description: 'Read current charging state and plug type (usb, ac, wireless, dock).',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.dnd': const ToolDefinition(
      name: 'device.dnd',
      description: 'Read Do Not Disturb status and current mode.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.bluetooth': const ToolDefinition(
      name: 'device.bluetooth',
      description: 'Read Bluetooth status and connected devices when permission is available.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.dnd.set': const ToolDefinition(
      name: 'device.dnd.set',
      description: 'Toggle Do Not Disturb on or off. '
          'Args: enabled (bool, required), mode (string, optional: priority_only | alarms_only | total_silence, default priority_only). '
          'Requires notification policy access permission.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'enabled': 'bool (required, true=on false=off)',
        'mode': 'string (optional: priority_only | alarms_only | total_silence)',
      },
    ),
    'device.wifi.reconnect': const ToolDefinition(
      name: 'device.wifi.reconnect',
      description: 'Reconnect to the last known WiFi network. WiFi must be enabled first.',
      risk: 'sensitive',
      requiresConfirmation: true,
    ),
    'device.bluetooth.set': const ToolDefinition(
      name: 'device.bluetooth.set',
      description: 'Toggle Bluetooth on or off. Requires Nearby Devices permission on Android 12+. '
          'Args: enabled (bool, required).',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'enabled': 'bool (required, true=on false=off)'},
    ),
    'device.wifi': const ToolDefinition(
      name: 'device.wifi',
      description: 'Read detailed WiFi status: enabled, connected, SSID, signal strength, link speed, frequency, IP address.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.cellular': const ToolDefinition(
      name: 'device.cellular',
      description: 'Read cellular/mobile data status: SIM ready, data connected, network type (4G/5G/LTE), operator, roaming.',
      risk: 'safe',
      requiresConfirmation: false,
    ),

    // ── Notification Intelligence ───────────────────────────────────────
    'notification.status': const ToolDefinition(
      name: 'notification.status',
      description: 'Check whether notification access is granted. Use this BEFORE other notification.* tools to verify availability.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'notification.read_recent': const ToolDefinition(
      name: 'notification.read_recent',
      description: 'Read the most recent Android notifications from the read-only cache. Returns app name, title, text, timestamp.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'limit': 'int (optional, default 10, max 100)'},
    ),
    'notification.summarize': const ToolDefinition(
      name: 'notification.summarize',
      description: 'Summarize recent notifications grouped by app. USE when user asks "ringkas notifikasi" or "ada notif apa".',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'limit': 'int (optional, default 25, max 100)'},
    ),
    'notification.classify': const ToolDefinition(
      name: 'notification.classify',
      description: 'Classify which recent notifications look important (urgent wording, mentions, deadlines). Read-only.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'limit': 'int (optional, default 15, max 100)'},
    ),
    'notification.reply_suggestion': const ToolDefinition(
      name: 'notification.reply_suggestion',
      description: 'Generate a SUGGESTED reply for a notification. DOES NOT SEND. User must copy or send manually.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'notificationId': 'string (required, id from notification.read_recent)',
        'tone': 'string (optional: casual | formal | friendly. Default casual)',
      },
    ),
    'notification.open_app': const ToolDefinition(
      name: 'notification.open_app',
      description: 'Open the source app of a specific notification. Resolves package then uses app.open flow.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'notificationId': 'string (required, id from notification.read_recent)'},
    ),

    // ── Notes ────────────────────────────────────────────────────────────
    'notes.create': const ToolDefinition(
      name: 'notes.create',
      description: 'Create a markdown note. Use when user says "catat", "simpan", "buat note".',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'title': 'string (required)',
        'content': 'string (markdown body)',
        'tags': 'list<string> (optional)',
        'source': 'string (optional, default runtime)',
      },
    ),
    'notes.list_recent': const ToolDefinition(
      name: 'notes.list_recent',
      description: 'List recent notes sorted by last updated.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'limit': 'int (optional, default 10)'},
    ),
    'notes.read': const ToolDefinition(
      name: 'notes.read',
      description: 'Read a note by ID. Returns full markdown content.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'noteId': 'string (required)'},
    ),
    'notes.search': const ToolDefinition(
      name: 'notes.search',
      description: 'Search notes by keyword in title, content, and tags.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'query': 'string (required)'},
    ),
    'notes.update': const ToolDefinition(
      name: 'notes.update',
      description: 'Update an existing note. Requires confirmation before overwriting.',
      risk: 'sensitive-lite',
      requiresConfirmation: true,
      inputSchema: {
        'noteId': 'string (required)',
        'title': 'string (optional)',
        'content': 'string (optional)',
        'tags': 'list<string> (optional)',
      },
    ),
    'notes.delete': const ToolDefinition(
      name: 'notes.delete',
      description: 'Delete a note permanently. Requires confirmation.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'noteId': 'string (required)'},
    ),
    'notes.export': const ToolDefinition(
      name: 'notes.export',
      description: 'Export notes as markdown files to the agent workspace notes/ folder. Pass empty noteIds to export all.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'agentName': 'string (required)',
        'noteIds': 'list<string> (optional, empty = all)',
      },
    ),

    // ─── Files Module ──────────────────────────────────────────────────────────

    'files.create': const ToolDefinition(
      name: 'files.create',
      description: 'Create a new file in the agent workspace. Fails if file already exists.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'path': 'string (required, relative to workspace)',
        'content': 'string (optional, file content)',
      },
    ),
    'files.read': const ToolDefinition(
      name: 'files.read',
      description: 'Read the content of a file in the agent workspace.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'path': 'string (required, relative to workspace)'},
    ),
    'files.write': const ToolDefinition(
      name: 'files.write',
      description: 'Write or overwrite content to a file in the agent workspace.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'path': 'string (required, relative to workspace)',
        'content': 'string (required)',
        'append': 'bool (optional, default false)',
      },
    ),
    'files.delete': const ToolDefinition(
      name: 'files.delete',
      description: 'Delete a file or directory in the agent workspace. Requires confirmation.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'path': 'string (required, relative to workspace)'},
    ),
    'files.list': const ToolDefinition(
      name: 'files.list',
      description: 'List files and directories in the agent workspace. Empty path = workspace root.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'path': 'string (optional, relative to workspace, empty = root)'},
    ),
    'files.move': const ToolDefinition(
      name: 'files.move',
      description: 'Move or rename a file/directory within the agent workspace.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'from': 'string (required, relative source path)',
        'to': 'string (required, relative destination path)',
      },
    ),
    'files.mkdir': const ToolDefinition(
      name: 'files.mkdir',
      description: 'Create a directory in the agent workspace.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'path': 'string (required, relative to workspace)'},
    ),

    // ─── Calendar Module ───────────────────────────────────────────────────────

    'calendar.create': const ToolDefinition(
      name: 'calendar.create',
      description: 'Create a new calendar event.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'title': 'string (required)',
        'startTime': 'ISO8601 string (required)',
        'endTime': 'ISO8601 string (optional, defaults +1h)',
        'description': 'string (optional)',
        'allDay': 'bool (optional, default false)',
        'color': 'string (optional, hex)',
        'tags': 'list<string> (optional)',
      },
    ),
    'calendar.today': const ToolDefinition(
      name: 'calendar.today',
      description: "Get today's calendar events.",
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'calendar.list': const ToolDefinition(
      name: 'calendar.list',
      description: 'List calendar events within a date range.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'from': 'ISO8601 string (required)',
        'to': 'ISO8601 string (required)',
        'limit': 'int (optional, default 20)',
      },
    ),
    'calendar.read': const ToolDefinition(
      name: 'calendar.read',
      description: 'Read a single calendar event by ID.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'eventId': 'string (required)'},
    ),
    'calendar.update': const ToolDefinition(
      name: 'calendar.update',
      description: 'Update an existing calendar event.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'eventId': 'string (required)',
        'title': 'string (optional)',
        'description': 'string (optional)',
        'startTime': 'ISO8601 (optional)',
        'endTime': 'ISO8601 (optional)',
        'allDay': 'bool (optional)',
        'color': 'string (optional)',
        'tags': 'list<string> (optional)',
      },
    ),
    'calendar.delete': const ToolDefinition(
      name: 'calendar.delete',
      description: 'Delete a calendar event. Requires confirmation.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'eventId': 'string (required)'},
    ),

  };

  /// Get all registered tool names.
  List<String> get registeredTools => _registry.keys.toList();

  /// Check if a tool is registered.
  bool isRegistered(String name) => _registry.containsKey(name);

  /// Get the authoritative definition for a tool.
  /// Risk level comes from HERE, not from LLM output.
  ToolDefinition? getDefinition(String name) => _registry[name];

  /// Build formatted tool descriptions for the LLM prompt.
  /// Format: "- toolName: description. Risk: X. [Args: ...] [Requires confirmation.]"
  List<String> buildAllToolDescriptions() {
    final descriptions = <String>[];
    for (final def in _registry.values) {
      final parts = StringBuffer();
      parts.write('- ${def.name}: ${def.description} Risk: ${def.risk}.');
      if (def.requiresConfirmation) {
        parts.write(' Requires confirmation.');
      }
      if (def.inputSchema.isNotEmpty) {
        final args = def.inputSchema.entries
            .map((e) => '${e.key} (${e.value})')
            .join(', ');
        parts.write(' Args: $args.');
      }
      descriptions.add(parts.toString());
    }
    return descriptions;
  }

  /// Validate a tool call request against the registry.
  /// Returns null if valid, or an error message if invalid.
  String? validate(ToolCallRequest request) {
    if (!isRegistered(request.name)) {
      return 'Unknown tool: ${request.name}. Not registered.';
    }
    return null;
  }

  /// Execute a tool. Returns the result.
  /// IMPORTANT: Does NOT execute if tool requires confirmation.
  Future<ToolExecutionResult> execute(ToolCallRequest request) async {
    final definition = _registry[request.name];
    if (definition == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Tool not found: ${request.name}',
      );
    }

    // Enforce confirmation from registry definition, not LLM.
    if (definition.requiresConfirmation) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'REQUIRES_CONFIRMATION',
      );
    }

    return _dispatch(request);
  }

  /// Force-execute a tool (user already confirmed). Bypasses confirmation.
  Future<ToolExecutionResult> forceExecute(ToolCallRequest request) async {
    final definition = _registry[request.name];
    if (definition == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Tool not found: ${request.name}',
      );
    }
    return _dispatch(request);
  }

  Future<ToolExecutionResult> _dispatch(ToolCallRequest request) async {
    switch (request.name) {
      case 'clipboard.read':
        return _executeClipboardRead();
      case 'clipboard.write':
        return _executeClipboardWrite(request.args);
      case 'app.resolve':
        return _executeAppResolve(request.args);
      case 'app.open':
        return _executeAppOpen(request.args);
      case 'app.list_installed':
        return _executeListInstalledApps();
      case 'settings.open':
        return _executeOpenSettings(request.args);
      case 'intent.open_url':
        return _executeOpenUrl(request.args);
      case 'device.battery':
        return _executeDeviceBattery();
      case 'device.network':
        return _executeDeviceNetwork();
      case 'device.storage':
        return _executeDeviceStorage();
      case 'device.time':
        return _executeDeviceTime();
      case 'device.locale':
        return _executeDeviceLocale();
      case 'device.summary':
        return _executeDeviceSummary();
      case 'device.foreground_app':
        return _executeDeviceForegroundApp();
      case 'device.usage_stats':
        return _executeDeviceUsageStats(request.args);
      case 'device.charging':
        return _executeDeviceCharging();
      case 'device.dnd':
        return _executeDeviceDnd();
      case 'device.bluetooth':
        return _executeDeviceBluetooth();
      case 'device.dnd.set':
        return _executeDeviceDndSet(request.args);
      case 'device.wifi.reconnect':
        return _executeDeviceWifiReconnect();
      case 'device.bluetooth.set':
        return _executeDeviceBluetoothSet(request.args);
      case 'device.wifi':
        return _executeDeviceWifi();
      case 'device.cellular':
        return _executeDeviceCellular();
      case 'notification.status':
        return _executeNotificationStatus();
      case 'notification.read_recent':
        return _executeNotificationReadRecent(request.args);
      case 'notification.summarize':
        return _executeNotificationSummarize(request.args);
      case 'notification.classify':
        return _executeNotificationClassify(request.args);
      case 'notification.reply_suggestion':
        return _executeNotificationReplySuggestion(request.args);
      case 'notification.open_app':
        return _executeNotificationOpenApp(request.args);
      case 'notes.create':
        return _notesTools().executeCreate(request.args);
      case 'notes.list_recent':
        return _notesTools().executeListRecent(request.args);
      case 'notes.read':
        return _notesTools().executeRead(request.args);
      case 'notes.search':
        return _notesTools().executeSearch(request.args);
      case 'notes.update':
        return _notesTools().executeUpdate(request.args);
      case 'notes.delete':
        return _notesTools().executeDelete(request.args);
      case 'notes.export':
        return _notesTools().executeExport(request.args);
      case 'files.create':
        return _filesTools().executeCreate(request.args);
      case 'files.read':
        return _filesTools().executeRead(request.args);
      case 'files.write':
        return _filesTools().executeWrite(request.args);
      case 'files.delete':
        return _filesTools().executeDelete(request.args);
      case 'files.list':
        return _filesTools().executeList(request.args);
      case 'files.move':
        return _filesTools().executeMove(request.args);
      case 'files.mkdir':
        return _filesTools().executeMkdir(request.args);
      case 'calendar.create':
        return _calendarTools().executeCreate(request.args);
      case 'calendar.today':
        return _calendarTools().executeToday(request.args);
      case 'calendar.list':
        return _calendarTools().executeList(request.args);
      case 'calendar.read':
        return _calendarTools().executeRead(request.args);
      case 'calendar.update':
        return _calendarTools().executeUpdate(request.args);
      case 'calendar.delete':
        return _calendarTools().executeDelete(request.args);
      default:
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'No implementation for tool: ${request.name}',
        );
    }
  }

  Future<ToolExecutionResult> _executeClipboardRead() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      return ToolExecutionResult(
        success: true,
        toolName: 'clipboard.read',
        data: {'text': text},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'clipboard.read',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeClipboardWrite(
      Map<String, dynamic> args) async {
    try {
      final text = args['text'] as String? ?? '';
      await Clipboard.setData(ClipboardData(text: text));
      return ToolExecutionResult(
        success: true,
        toolName: 'clipboard.write',
        data: {'written': true},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'clipboard.write',
        error: e.toString(),
      );
    }
  }

  static const _appChannel = MethodChannel('com.meowagent/app_control');

  Future<ToolExecutionResult> _executeAppResolve(Map<String, dynamic> args) async {
    try {
      final query = (args['query'] as String? ?? args['name'] as String? ?? '').trim();
      if (query.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'app.resolve',
          error: 'Empty query. Provide an app name to resolve.',
        );
      }
      final result = await AppAliasResolver.resolve(query);
      if (result == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'app.resolve',
          data: {'query': query, 'matched': false},
          error: 'No app matched query: "$query"',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'app.resolve',
        data: {
          'query': query,
          'matched': true,
          'app': result.toJson(),
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app.resolve',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeAppOpen(Map<String, dynamic> args) async {
    try {
      // Prefer explicit package; fall back to resolving "name" via resolver.
      var pkg = (args['package'] as String? ?? '').trim();
      final friendlyName = (args['name'] as String? ?? args['query'] as String? ?? '').trim();

      if (pkg.isEmpty && friendlyName.isNotEmpty) {
        final result = await AppAliasResolver.resolve(friendlyName);
        if (result != null && result.confidence >= 0.85) {
          pkg = result.packageName;
        } else if (result != null) {
          // Below high-confidence threshold — surface alternatives.
          return ToolExecutionResult(
            success: false,
            toolName: 'app.open',
            data: {
              'matched': result.toJson(),
              'low_confidence': true,
            },
            error: 'Low confidence match (${result.confidence.toStringAsFixed(2)}) for "$friendlyName". Best guess: ${result.name}. Use app.resolve and ask user to confirm.',
          );
        }
      }

      if (pkg.isEmpty) {
        return ToolExecutionResult(
          success: false,
          toolName: 'app.open',
          error: 'Could not resolve app. Call app.resolve first to get the package name.',
        );
      }

      final success = await _appChannel.invokeMethod<bool>('openApp', {'package': pkg}) ?? false;
      return ToolExecutionResult(
        success: success,
        toolName: 'app.open',
        data: {'package': pkg, 'opened': success},
        error: success ? null : 'App not found or could not be launched: $pkg',
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app.open',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeListInstalledApps() async {
    try {
      final raw = await _appChannel.invokeMethod<List>('listInstalledApps');
      final apps = raw?.map((e) => Map<String, String>.from(e as Map)).toList() ?? [];
      return ToolExecutionResult(
        success: true,
        toolName: 'app.list_installed',
        data: {'apps': apps, 'count': apps.length},
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'app.list_installed', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeOpenSettings(Map<String, dynamic> args) async {
    try {
      final action = args['action'] as String? ?? 'android.settings.SETTINGS';
      await _appChannel.invokeMethod<bool>('openSettings', {'action': action});
      return ToolExecutionResult(
        success: true,
        toolName: 'settings.open',
        data: {'action': action},
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'settings.open', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeOpenUrl(Map<String, dynamic> args) async {
    try {
      var url = (args['url'] as String? ?? '').trim();
      if (url.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'intent.open_url',
          error: 'Empty URL.',
        );
      }
      // Auto-prefix scheme if missing.
      final lower = url.toLowerCase();
      if (!lower.startsWith('http://') &&
          !lower.startsWith('https://') &&
          !lower.contains('://')) {
        url = 'https://$url';
      }
      final success = await _appChannel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
      return ToolExecutionResult(
        success: success,
        toolName: 'intent.open_url',
        data: {'url': url, 'opened': success},
        error: success ? null : 'Failed to open URL: $url',
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'intent.open_url', error: e.toString());
    }
  }

  // ── Device Context helpers ───────────────────────────────────────────

  DeviceContextRepository _deviceRepo() => DeviceContextRepository(
        service: DeviceContextService(),
        moduleRepository: ModuleRepository(),
      );

  NotesTools _notesTools() => NotesTools();

  FilesTools _filesTools() => FilesTools(agentName: agentName);

  CalendarTools _calendarTools() => CalendarTools();

  Future<ToolExecutionResult> _executeDeviceBattery() async {
    try {
      final repo = _deviceRepo();
      final info = await repo.getBattery();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.battery',
          error: 'Device Context module is disabled or battery info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.battery',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.battery', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceNetwork() async {
    try {
      final info = await _deviceRepo().getNetwork();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.network',
          error: 'Device Context module is disabled or network info not allowed.',
        );
      }
      return ToolExecutionResult(success: true, toolName: 'device.network', data: info.toJson());
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.network', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceStorage() async {
    try {
      final info = await _deviceRepo().getStorage();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.storage',
          error: 'Device Context module is disabled or storage info not allowed.',
        );
      }
      return ToolExecutionResult(success: true, toolName: 'device.storage', data: info.toJson());
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.storage', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceTime() async {
    try {
      final info = await _deviceRepo().getTime();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.time',
          error: 'Device Context module is disabled or time info not allowed.',
        );
      }
      return ToolExecutionResult(success: true, toolName: 'device.time', data: info.toJson());
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.time', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceLocale() async {
    try {
      final info = await _deviceRepo().getLocale();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.locale',
          error: 'Device Context module is disabled or locale info not allowed.',
        );
      }
      return ToolExecutionResult(success: true, toolName: 'device.locale', data: info.toJson());
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.locale', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceSummary() async {
    try {
      final result = await _deviceRepo().getSummary();
      if (result.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'device.summary',
          error: result.error,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.summary',
        data: result.data ?? {},
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.summary', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceForegroundApp() async {
    try {
      final info = await _deviceRepo().getForegroundApp();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.foreground_app',
          error: 'Device Context module is disabled or foreground app detection not allowed.',
        );
      }
      return ToolExecutionResult(
        success: info.available,
        toolName: 'device.foreground_app',
        data: info.toJson(),
        error: info.available ? null : 'Foreground app unavailable: ${info.reason}',
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.foreground_app', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceUsageStats(Map<String, dynamic> args) async {
    try {
      final days = (args['days'] as num?)?.toInt() ?? 7;
      final result = await _deviceRepo().getUsageStats(days: days);
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.usage_stats',
          error: 'Device Context module is disabled or foreground app permission not granted.',
        );
      }
      final available = result['available'] as bool? ?? false;
      if (!available) {
        return ToolExecutionResult(
          success: false,
          toolName: 'device.usage_stats',
          error: 'Usage stats unavailable: ${result['reason'] ?? 'unknown'}',
          data: result,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.usage_stats',
        data: result,
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.usage_stats', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceCharging() async {
    try {
      final info = await _deviceRepo().getCharging();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.charging',
          error: 'Device Context module is disabled or charging info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.charging',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.charging', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceDnd() async {
    try {
      final info = await _deviceRepo().getDnd();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.dnd',
          error: 'Device Context module is disabled or DND status not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.dnd',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.dnd', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceBluetooth() async {
    try {
      final info = await _deviceRepo().getBluetooth();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.bluetooth',
          error: 'Device Context module is disabled or Bluetooth status not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.bluetooth',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.bluetooth', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceDndSet(Map<String, dynamic> args) async {
    try {
      final enabled = args['enabled'] as bool? ?? false;
      final mode = args['mode'] as String?;
      final result = await _deviceRepo().setDnd(enabled: enabled, mode: mode);
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.dnd.set',
          error: 'Device Context module is disabled or DND control not allowed.',
        );
      }
      final success = result['success'] as bool? ?? false;
      if (!success) {
        return ToolExecutionResult(
          success: false,
          toolName: 'device.dnd.set',
          error: result['error'] as String? ?? 'Failed to set DND mode.',
          data: result,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.dnd.set',
        data: result,
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.dnd.set', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceWifiReconnect() async {
    try {
      final result = await _deviceRepo().reconnectWifi();
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.wifi.reconnect',
          error: 'Device Context module is disabled or network control not allowed.',
        );
      }
      final success = result['success'] as bool? ?? false;
      return ToolExecutionResult(
        success: success,
        toolName: 'device.wifi.reconnect',
        data: result,
        error: success ? null : result['error'] as String?,
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.wifi.reconnect', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceBluetoothSet(Map<String, dynamic> args) async {
    try {
      final enabled = args['enabled'] as bool? ?? false;
      final result = await _deviceRepo().setBluetoothEnabled(enabled: enabled);
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.bluetooth.set',
          error: 'Device Context module is disabled or Bluetooth control not allowed.',
        );
      }
      final success = result['success'] as bool? ?? false;
      return ToolExecutionResult(
        success: success,
        toolName: 'device.bluetooth.set',
        data: result,
        error: success ? null : result['error'] as String?,
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.bluetooth.set', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceWifi() async {
    try {
      final result = await _deviceRepo().getWifiStatus();
      if (result.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'device.wifi',
          error: result.error,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.wifi',
        data: result.data,
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.wifi', error: e.toString());
    }
  }

  Future<ToolExecutionResult> _executeDeviceCellular() async {
    try {
      final result = await _deviceRepo().getCellularStatus();
      if (result.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'device.cellular',
          error: result.error,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.cellular',
        data: result.data,
      );
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: 'device.cellular', error: e.toString());
    }
  }

  // ── Notification Intelligence helpers ─────────────────────────────────

  NotificationRepository _notifRepo() => NotificationRepository(
        service: NotificationService(),
        moduleRepository: ModuleRepository(),
      );

  Future<ToolExecutionResult> _executeNotificationStatus() async {
    try {
      final res = await _notifRepo().getStatus();
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notification.status',
          error: res.error,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'notification.status',
        data: {
          'granted': res.granted,
          'hint': res.granted
              ? null
              : 'User must enable Notification access in Android Settings.',
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.status',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeNotificationReadRecent(
    Map<String, dynamic> args,
  ) async {
    try {
      final limit = (args['limit'] as num?)?.toInt() ?? 10;
      final res = await _notifRepo().getRecent(limit: limit);
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notification.read_recent',
          error: res.error,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'notification.read_recent',
        data: {
          'count': res.data!.length,
          'notifications': res.data!.map((n) => n.toJson()).toList(),
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.read_recent',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeNotificationSummarize(
    Map<String, dynamic> args,
  ) async {
    try {
      final limit = (args['limit'] as num?)?.toInt() ?? 25;
      final res = await _notifRepo().getForSummary(limit: limit);
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notification.summarize',
          error: res.error,
        );
      }
      // Group by app for the LLM to summarize naturally.
      final byApp = <String, int>{};
      for (final n in res.data!) {
        byApp[n.appName] = (byApp[n.appName] ?? 0) + 1;
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'notification.summarize',
        data: {
          'count': res.data!.length,
          'byApp': byApp,
          'notifications': res.data!.map((n) => n.toJson()).toList(),
          'hint':
              'Summarize naturally in Indonesian. Group by app. Mention notable senders/titles.',
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.summarize',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeNotificationClassify(
    Map<String, dynamic> args,
  ) async {
    try {
      final limit = (args['limit'] as num?)?.toInt() ?? 15;
      final res = await _notifRepo().getForClassify(limit: limit);
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notification.classify',
          error: res.error,
        );
      }
      // Heuristic flagging — urgent keywords in title or text.
      final urgentRegex = RegExp(
        r'\b(urgent|penting|asap|deadline|segera|tolong|help|bayar|invoice|otp|kode|code|verify|verifikasi|password|login|alert|warning|error|gagal|failed|reminder|booking|tiket|approve|approval|menunggu|waiting|pending)\b',
        caseSensitive: false,
      );
      final flagged = <Map<String, dynamic>>[];
      for (final n in res.data!) {
        final haystack = '${n.title ?? ''} ${n.text ?? ''}';
        if (urgentRegex.hasMatch(haystack)) {
          flagged.add({
            'id': n.id,
            'appName': n.appName,
            'title': n.title,
            'text': n.text,
            'reason': 'matched urgent keyword',
          });
        }
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'notification.classify',
        data: {
          'totalScanned': res.data!.length,
          'flagged': flagged,
          'all': res.data!.map((n) => n.toJson()).toList(),
          'hint':
              'Use the flagged list as starting point; re-rank with judgment. Reply naturally in Indonesian.',
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.classify',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeNotificationReplySuggestion(
    Map<String, dynamic> args,
  ) async {
    try {
      final id = (args['notificationId'] as String?)?.trim() ?? '';
      final tone = (args['tone'] as String?)?.trim().toLowerCase() ?? 'casual';
      if (id.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notification.reply_suggestion',
          error: 'Missing required arg: notificationId',
        );
      }
      final res = await _notifRepo().getForReply(id);
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notification.reply_suggestion',
          error: res.error,
        );
      }
      final n = res.data!;
      return ToolExecutionResult(
        success: true,
        toolName: 'notification.reply_suggestion',
        data: {
          'source': n.toJson(),
          'tone': tone,
          'hint':
              'Generate ONE short reply suggestion in Indonesian (or matching the source language) with $tone tone. '
                  'DO NOT actually send. The user will copy the reply manually. '
                  'Reply field key: "suggestion".',
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.reply_suggestion',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeNotificationOpenApp(
    Map<String, dynamic> args,
  ) async {
    try {
      final id = (args['notificationId'] as String?)?.trim() ?? '';
      if (id.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notification.open_app',
          error: 'Missing required arg: notificationId',
        );
      }
      final res = await _notifRepo().getForOpenApp(id);
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notification.open_app',
          error: res.error,
        );
      }
      final pkg = res.data!.packageName;
      // Reuse app.open flow via MethodChannel.
      const channel = MethodChannel('com.meowagent/app_control');
      final success = await channel.invokeMethod<bool>('openApp', {'package': pkg}) ?? false;
      return ToolExecutionResult(
        success: success,
        toolName: 'notification.open_app',
        data: {
          'package': pkg,
          'appName': res.data!.appName,
          'opened': success,
        },
        error: success ? null : 'Failed to open app: $pkg',
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.open_app',
        error: e.toString(),
      );
    }
  }
}
