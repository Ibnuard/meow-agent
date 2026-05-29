import 'package:flutter/services.dart';

import '../../features/agents/data/agent_model.dart';
import '../../features/agents/data/agent_repository.dart';
import '../../features/chat/data/chat_history_service.dart';
import '../../features/chat/data/unread_service.dart';
import '../../features/modules/device_context/device_context_repository.dart';
import '../../features/modules/device_context/device_context_service.dart';
import '../../features/modules/data/module_repository.dart';
import '../../features/modules/calendar/calendar_tools.dart';
import '../../features/modules/files/files_tools.dart';
import '../../features/modules/notes/notes_tools.dart';
import '../../features/modules/workflows/workflow_tools.dart';
import '../../features/modules/notification_intelligence/agent_notification_service.dart';
import '../../features/modules/notification_intelligence/notification_repository.dart';
import '../../features/modules/notification_intelligence/notification_service.dart';
import '../../features/providers/data/provider_repository.dart';
import 'app_alias_resolver.dart';
import 'runtime_models.dart';
import 'system_tools.dart';
import 'tool_permission_policy.dart';

/// Routes tool calls to their implementations.
/// Validates tool existence and enforces risk/confirmation rules.
class ToolRouter {
  ToolRouter({
    this.agentName = '',
    this.agentId = '',
    ModuleRepository? moduleRepository,
    this.agentRepository,
    this.providerRepository,
    this.saveAgent,
    this.deleteAgent,
  }) : moduleRepository = moduleRepository ?? ModuleRepository();

  final ModuleRepository moduleRepository;
  final AgentRepository? agentRepository;
  final ProviderRepository? providerRepository;
  final Future<void> Function(AgentModel agent)? saveAgent;
  final Future<void> Function(String id)? deleteAgent;

  /// The current agent name — used by workspace-scoped tools (files module).
  String agentName;

  /// The current agent id — used by data-scoped tools (workflows, etc.).
  String agentId;

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
      description:
          'Resolve a friendly app name (e.g. "wa", "toko ijo", "youtube") to a package name. ALWAYS call this first before app.open.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'query': 'string (friendly name to resolve)'},
    ),
    'app.open': const ToolDefinition(
      name: 'app.open',
      description:
          'Open an installed app by exact package name. Use app.resolve first to get the package name.',
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
      description:
          'Read a summary of battery, network, storage, time, and locale.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.foreground_app': const ToolDefinition(
      name: 'device.foreground_app',
      description:
          'Read the app that is CURRENTLY in the foreground RIGHT NOW. '
          'This does NOT provide usage history, screen time, or statistics. '
          'If asked about past usage or most-used apps, say you cannot access that data.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.usage_stats': const ToolDefinition(
      name: 'device.usage_stats',
      description:
          'Read real app usage statistics for the past N days (default 7). '
          'Returns top 10 user-facing apps sorted by total usage time in minutes. '
          'Use this when asked about most-used apps, screen time, or app usage history. '
          'Args: days (int, optional, default 7).',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'days': 'int (optional, default 7)'},
    ),
    'device.charging': const ToolDefinition(
      name: 'device.charging',
      description:
          'Read current charging state and plug type (usb, ac, wireless, dock).',
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
      description:
          'Read Bluetooth status and connected devices when permission is available.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.dnd.set': const ToolDefinition(
      name: 'device.dnd.set',
      description:
          'Toggle Do Not Disturb on or off. '
          'Args: enabled (bool, required), mode (string, optional: priority_only | alarms_only | total_silence, default priority_only). '
          'Requires notification policy access permission.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'enabled': 'bool (required, true=on false=off)',
        'mode':
            'string (optional: priority_only | alarms_only | total_silence)',
      },
    ),
    'device.wifi.reconnect': const ToolDefinition(
      name: 'device.wifi.reconnect',
      description:
          'Reconnect to the last known WiFi network. WiFi must be enabled first.',
      risk: 'sensitive',
      requiresConfirmation: true,
    ),
    'device.bluetooth.set': const ToolDefinition(
      name: 'device.bluetooth.set',
      description:
          'Toggle Bluetooth on or off. Requires Nearby Devices permission on Android 12+. '
          'Args: enabled (bool, required).',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'enabled': 'bool (required, true=on false=off)'},
    ),
    'device.wifi': const ToolDefinition(
      name: 'device.wifi',
      description:
          'Read detailed WiFi status: enabled, connected, SSID, signal strength, link speed, frequency, IP address.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'device.cellular': const ToolDefinition(
      name: 'device.cellular',
      description:
          'Read cellular/mobile data status: SIM ready, data connected, network type (4G/5G/LTE), operator, roaming.',
      risk: 'safe',
      requiresConfirmation: false,
    ),

    // ── Notification Intelligence ───────────────────────────────────────
    'notification.status': const ToolDefinition(
      name: 'notification.status',
      description:
          'Check whether notification access is granted. Use this BEFORE other notification.* tools to verify availability.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'notification.read_recent': const ToolDefinition(
      name: 'notification.read_recent',
      description:
          'Read the most recent Android notifications from the read-only cache. Returns app name, title, text, timestamp.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'limit': 'int (optional, default 10, max 100)'},
    ),
    'notification.summarize': const ToolDefinition(
      name: 'notification.summarize',
      description:
          'Summarize recent notifications grouped by app. USE when user asks "ringkas notifikasi" or "ada notif apa".',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'limit': 'int (optional, default 25, max 100)'},
    ),
    'notification.classify': const ToolDefinition(
      name: 'notification.classify',
      description:
          'Classify which recent notifications look important (urgent wording, mentions, deadlines). Read-only.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'limit': 'int (optional, default 15, max 100)'},
    ),
    'notification.reply_suggestion': const ToolDefinition(
      name: 'notification.reply_suggestion',
      description:
          'Generate a SUGGESTED reply for a notification. DOES NOT SEND. User must copy or send manually.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'notificationId': 'string (required, id from notification.read_recent)',
        'tone': 'string (optional: casual | formal | friendly. Default casual)',
      },
    ),
    'notification.open_app': const ToolDefinition(
      name: 'notification.open_app',
      description:
          'Open the source app of a specific notification. Resolves package then uses app.open flow.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'notificationId': 'string (required, id from notification.read_recent)',
      },
    ),
    'notification.create_local': const ToolDefinition(
      name: 'notification.create_local',
      description:
          'Push a local Android notification from the agent to the user. Use for reminders, digests, alerts, or anything that should reach the user even if the app is backgrounded. Style controls importance: silent (low), normal (default), alarm (high + vibration). NOT for chat replies — use chat.send for that.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'title': 'string (required)',
        'body': 'string (required, supports plain text)',
        'style': 'string (optional: silent | normal | alarm. default normal)',
      },
    ),

    // ── Notes ────────────────────────────────────────────────────────────
    'notes.create': const ToolDefinition(
      name: 'notes.create',
      description:
          'Create a markdown note. Use when user says "catat", "simpan", "buat note".',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'title': 'string (required)',
        'content': 'string (markdown body)',
        'tags': 'list<string> (optional)',
        'source': 'string (optional, default runtime)',
      },
      operation: 'create',
      targetEntity: 'note',
      selectorArgs: ['title'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'note',
        expectedDataKeys: ['noteId'],
      ),
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
      description:
          'Update an existing note. Requires confirmation before overwriting.',
      risk: 'sensitive-lite',
      requiresConfirmation: true,
      inputSchema: {
        'noteId': 'string (required)',
        'title': 'string (optional)',
        'content': 'string (optional)',
        'tags': 'list<string> (optional)',
      },
      operation: 'update',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'note',
        expectedDataKeys: ['updated'],
      ),
    ),
    'notes.delete': const ToolDefinition(
      name: 'notes.delete',
      description: 'Delete a note permanently. Requires confirmation.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'noteId': 'string (required)'},
      operation: 'delete',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'note',
        expectedDataKeys: ['deleted'],
      ),
    ),
    'notes.export': const ToolDefinition(
      name: 'notes.export',
      description:
          'Export notes as markdown files to the agent workspace notes/ folder. Pass empty noteIds to export all.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'agentName': 'string (required)',
        'noteIds': 'list<string> (optional, empty = all)',
      },
    ),
    'notes.pin': const ToolDefinition(
      name: 'notes.pin',
      description:
          'Pin a note so it stays at the top of the list. Reversible via notes.unpin.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'noteId': 'string (required)'},
      operation: 'update',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
    ),
    'notes.unpin': const ToolDefinition(
      name: 'notes.unpin',
      description: 'Remove pinned status from a note.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'noteId': 'string (required)'},
      operation: 'update',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
    ),
    'notes.archive': const ToolDefinition(
      name: 'notes.archive',
      description:
          'Archive a note (hidden from main list but kept). Use when user wants to declutter without deleting. Reversible via notes.unarchive.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'noteId': 'string (required)'},
      operation: 'update',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
    ),
    'notes.unarchive': const ToolDefinition(
      name: 'notes.unarchive',
      description: 'Restore an archived note back to the main list.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'noteId': 'string (required)'},
      operation: 'update',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
    ),
    'notes.append': const ToolDefinition(
      name: 'notes.append',
      description:
          'Append content to an existing note (additive, non-destructive). Useful for daily journals, running logs, accumulating ideas.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'noteId': 'string (required)',
        'content': 'string (required, markdown body to append)',
        'separator': 'string (optional, default = double newline)',
      },
      operation: 'update',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
    ),

    // ─── Files Module ──────────────────────────────────────────────────────────
    'files.create': const ToolDefinition(
      name: 'files.create',
      description:
          'Create a new file under the MeowAgent workspace root. Defaults to the calling agent. To target a peer agent use "Agents/<Name>/<rel>" — the runtime will require user confirmation. Fails if file already exists.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'path':
            'string (required, relative to own workspace OR "Agents/<Name>/..." for a peer)',
        'content': 'string (optional, file content)',
      },
      operation: 'create',
      targetEntity: 'file',
      selectorArgs: ['path'],
      postconditions: {'file_present': 'path'},
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'file',
        expectedDataKeys: ['path'],
      ),
    ),
    'files.read': const ToolDefinition(
      name: 'files.read',
      description:
          'Read a file under the MeowAgent workspace root. Use "Agents/<Name>/<rel>" to read a peer agent’s file (e.g. "Agents/Penulis/SOUL.md"); the runtime will require confirmation for cross-agent reads.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'path':
            'string (required, relative to own workspace OR "Agents/<Name>/..." for a peer)',
      },
      operation: 'read',
      targetEntity: 'file',
      selectorArgs: ['path'],
    ),
    'files.write': const ToolDefinition(
      name: 'files.write',
      description:
          'Write or overwrite content to a file under the MeowAgent workspace root. Cross-agent writes (e.g. "Agents/<Name>/SOUL.md") require user confirmation — use this when swapping or syncing peer-agent personas.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'path':
            'string (required, relative to own workspace OR "Agents/<Name>/..." for a peer)',
        'content': 'string (required)',
        'append': 'bool (optional, default false)',
      },
      operation: 'update',
      targetEntity: 'file',
      selectorArgs: ['path'],
      postconditions: {'file_present': 'path'},
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'file',
        expectedDataKeys: ['path'],
      ),
    ),
    'files.delete': const ToolDefinition(
      name: 'files.delete',
      description:
          'Delete a file or directory under the MeowAgent workspace root. Always requires confirmation — cross-agent paths are also surfaced for explicit user approval.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'path':
            'string (required, relative to own workspace OR "Agents/<Name>/..." for a peer)',
      },
      operation: 'delete',
      targetEntity: 'file',
      selectorArgs: ['path'],
      postconditions: {'file_absent': 'path'},
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'file',
        expectedDataKeys: ['deleted'],
      ),
    ),
    'files.list': const ToolDefinition(
      name: 'files.list',
      description:
          'List files and directories under the MeowAgent workspace root. Empty path = own workspace root. Use "Agents" to enumerate peer agents, or "Agents/<Name>" for a peer’s root — cross-agent reads ask for confirmation.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'path':
            'string (optional; empty = own root, "Agents/<Name>" for a peer)',
      },
      operation: 'list',
      targetEntity: 'file',
      selectorArgs: ['path'],
    ),
    'files.move': const ToolDefinition(
      name: 'files.move',
      description:
          'Move or rename a file/directory under the MeowAgent workspace root. Cross-agent moves (using "Agents/<Name>/..." on either side) require confirmation.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'from': 'string (required, relative or "Agents/<Name>/...")',
        'to': 'string (required, relative or "Agents/<Name>/...")',
      },
      operation: 'rename',
      targetEntity: 'file',
      selectorArgs: ['from', 'to'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'file',
        expectedDataKeys: ['to'],
      ),
    ),
    'files.mkdir': const ToolDefinition(
      name: 'files.mkdir',
      description:
          'Create a directory under the MeowAgent workspace root. Cross-agent creation ("Agents/<Name>/...") requires confirmation.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'path':
            'string (required, relative to own workspace OR "Agents/<Name>/..." for a peer)',
      },
      operation: 'create',
      targetEntity: 'file',
      selectorArgs: ['path'],
      postconditions: {'directory_present': 'path'},
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'file',
        expectedDataKeys: ['path'],
      ),
    ),
    'files.copy': const ToolDefinition(
      name: 'files.copy',
      description:
          'Copy a file or directory within the workspace. Source remains intact.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'from': 'string (required, source path)',
        'to': 'string (required, destination path)',
      },
      operation: 'create',
      targetEntity: 'file',
      selectorArgs: ['to'],
    ),
    'files.append': const ToolDefinition(
      name: 'files.append',
      description:
          'Append content to an existing file (additive, non-destructive). Auto-creates the file with the appended content if it does not exist. Inserts a newline before content if file does not end with one.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'path': 'string (required)',
        'content': 'string (required, text to append)',
      },
      operation: 'update',
      targetEntity: 'file',
      selectorArgs: ['path'],
    ),
    'files.metadata': const ToolDefinition(
      name: 'files.metadata',
      description:
          'Get file metadata: size, modified time, mime type, line count for small text files. Read-only, no content returned.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'path': 'string (required)'},
    ),
    'files.search': const ToolDefinition(
      name: 'files.search',
      description:
          'Search files by name pattern (glob: * and ?) and/or content keyword inside the agent workspace. Returns paths with content snippets. OMIT "root" to search the current agent\'s own workspace (this is what users normally mean). Only set "root" when user explicitly references a peer agent (e.g. "Agents/<Name>").',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'query': 'string (optional, content keyword; case-insensitive)',
        'namePattern':
            'string (optional, glob filename pattern e.g. *.md or report-*.txt)',
        'root':
            'string (optional, OMIT for own workspace. Only use "Agents/<Name>" for peer agents)',
        'maxResults': 'int (optional, 1-200, default 50)',
      },
    ),
    'files.tree': const ToolDefinition(
      name: 'files.tree',
      description:
          'Render a workspace directory as ASCII tree (1-8 depth). Useful for giving the user/LLM a structural overview without listing every file. OMIT "root" to render the current agent\'s own workspace (this is what users normally mean by "struktur folder agen ini" / "workspace structure"). Only set "root" when user explicitly references a peer agent (e.g. "Agents/<Name>"). Do NOT pass absolute paths from system.self output.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'root':
            'string (optional, OMIT for own workspace. Only use "Agents/<Name>" for peer agents)',
        'maxDepth': 'int (optional, 1-8, default 3)',
      },
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
      operation: 'create',
      targetEntity: 'calendar_event',
      selectorArgs: ['title'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'calendar_event',
        expectedDataKeys: ['eventId'],
      ),
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
      operation: 'update',
      targetEntity: 'calendar_event',
      selectorArgs: ['eventId'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'calendar_event',
        expectedDataKeys: ['updated'],
      ),
    ),
    'calendar.delete': const ToolDefinition(
      name: 'calendar.delete',
      description: 'Delete a calendar event. Requires confirmation.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'eventId': 'string (required)'},
      operation: 'delete',
      targetEntity: 'calendar_event',
      selectorArgs: ['eventId'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'calendar_event',
        expectedDataKeys: ['deleted'],
      ),
    ),
    'calendar.upcoming': const ToolDefinition(
      name: 'calendar.upcoming',
      description:
          'Agenda view: list upcoming events grouped by date for the next N days. Default 7 days.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'days': 'int (optional, 1-90, default 7)'},
    ),
    'calendar.conflicts': const ToolDefinition(
      name: 'calendar.conflicts',
      description:
          'Check whether a proposed time slot overlaps with existing events. Returns list of conflicting events.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'startTime': 'string (required, ISO8601)',
        'durationMinutes': 'int (optional, default 60)',
      },
    ),
    'calendar.free_slot': const ToolDefinition(
      name: 'calendar.free_slot',
      description:
          'Find available time slots of given duration within working hours. Use when user asks "cari waktu kosong" or "when am I free".',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'durationMinutes': 'int (optional, default 60)',
        'withinDays': 'int (optional, 1-30, default 7)',
        'dayStartHour': 'int (optional, 0-23, default 9)',
        'dayEndHour': 'int (optional, 1-24, default 17)',
        'maxResults': 'int (optional, 1-20, default 5)',
      },
    ),
    'calendar.link_note': const ToolDefinition(
      name: 'calendar.link_note',
      description:
          'Associate a note with a calendar event (meeting notes pattern). Stored as note:<id> tag on the event.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'eventId': 'string (required)',
        'noteId': 'string (required)',
      },
      operation: 'update',
      targetEntity: 'calendar_event',
      selectorArgs: ['eventId'],
    ),

    // ─── Workflow Module ─────────────────────────────────────────────────────────────
    'workflow.create': const ToolDefinition(
      name: 'workflow.create',
      description:
          'Create a scheduled, interval, or event-triggered workflow. Supports single-prompt or chained multi-step execution.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'title': 'string (required)',
        'prompt': 'string (required if steps not provided)',
        'agentId':
            'string (optional, defaults to caller agent; accepts agent UUID or display name to assign workflow to a specific agent)',
        'trigger':
            'object (required) - {type: schedule|interval|event, hour, minute, daysOfWeek, intervalMinutes, eventKind: batteryLow|batteryAbove|batteryFull|chargingStart|chargingStop|notificationKeyword|appOpened|wifiConnected|wifiDisconnected, eventParams: {keyword, package}}',
        'notification':
            'object (optional) - {style: silent|normal|alarm, showResult: bool}',
        'send_to_chat': 'bool (optional, default false)',
        'priority': 'string (optional) - low|normal|high|critical',
        'timeout_seconds': 'int (optional, default 60)',
        'steps':
            'list<object> (optional) - [{id, prompt, condition?, onFailure: stop|skip|retry, timeoutSeconds}]',
        'variables':
            'object (optional) - {key: defaultValue} accessed in prompts as {{key}}',
      },
      operation: 'create',
      targetEntity: 'workflow',
      selectorArgs: ['title'],
      postconditions: {'workflow_present': 'title'},
      verificationProbe: ToolVerificationProbe(
        kind: 'snapshot_contains',
        entityType: 'workflow',
        expectPresent: true,
        selectorArgKey: 'title',
      ),
    ),
    'workflow.create_from_template': const ToolDefinition(
      name: 'workflow.create_from_template',
      description:
          'Create a workflow from a pre-built template. Use workflow.list_templates to see available templates.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'template_id': 'string (required)'},
    ),
    'workflow.list_templates': const ToolDefinition(
      name: 'workflow.list_templates',
      description:
          'List all available workflow templates with their categories and metadata.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'workflow.list': const ToolDefinition(
      name: 'workflow.list',
      description:
          'List workflows. By default returns ALL workflows across the app, '
          'matching what the user sees in the Workflows screen. Pass '
          '"assignedTo" (agent id or name) to filter to one agent.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'assignedTo': 'string (optional, agent id or name to filter on)',
      },
      operation: 'list',
      targetEntity: 'workflow',
    ),
    'workflow.read': const ToolDefinition(
      name: 'workflow.read',
      description:
          'Read details of a specific workflow including steps and variables.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'id': 'string (required)'},
      operation: 'read',
      targetEntity: 'workflow',
      selectorArgs: ['id'],
    ),
    'workflow.update': const ToolDefinition(
      name: 'workflow.update',
      description: 'Update an existing workflow. Any field can be updated.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'id': 'string (required)',
        'agentId':
            'string (optional, accepts agent UUID or display name to re-assign the workflow to another agent)',
        'title': 'string (optional)',
        'prompt': 'string (optional)',
        'trigger': 'object (optional)',
        'notification': 'object (optional)',
        'send_to_chat': 'bool (optional)',
        'priority': 'string (optional)',
        'timeout_seconds': 'int (optional)',
        'steps': 'list<object> (optional)',
        'variables': 'object (optional)',
      },
      operation: 'update',
      targetEntity: 'workflow',
      selectorArgs: ['id', 'title'],
      postconditions: {'workflow_updated': 'id'},
      verificationProbe: ToolVerificationProbe(
        kind: 'snapshot_contains',
        entityType: 'workflow',
        expectPresent: true,
        selectorArgKey: 'id',
      ),
    ),
    'workflow.delete': const ToolDefinition(
      name: 'workflow.delete',
      description: 'Delete a workflow. Requires confirmation.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'id': 'string (required)'},
      operation: 'delete',
      targetEntity: 'workflow',
      selectorArgs: ['id', 'title'],
      postconditions: {'workflow_absent': 'id'},
      verificationProbe: ToolVerificationProbe(
        kind: 'snapshot_absent',
        entityType: 'workflow',
        expectPresent: false,
        selectorArgKey: 'id',
      ),
    ),
    'workflow.toggle': const ToolDefinition(
      name: 'workflow.toggle',
      description: 'Enable or disable a workflow.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'id': 'string (required)', 'enabled': 'bool (required)'},
      operation: 'toggle',
      targetEntity: 'workflow',
      selectorArgs: ['id', 'title'],
      postconditions: {'workflow_enabled': 'enabled'},
    ),

    // ─── Core System ─────────────────────────────────────────────────────────
    'system.self': const ToolDefinition(
      name: 'system.self',
      description:
          'Inspect the current agent identity, provider, workspace path, core markdown files, and capability counts.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'system.workspace.schema': const ToolDefinition(
      name: 'system.workspace.schema',
      description:
          'Describe the Meow Agent markdown model: system markdown standard vs mutable per-agent workspace markdown.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'system.workspace.read': const ToolDefinition(
      name: 'system.workspace.read',
      description:
          'Read one core markdown file from the current agent workspace. Use for SOUL.md, MEMORY.md, SKILLS.md, or HEARTBEAT.md.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'file': 'string (required: SOUL.md|MEMORY.md|SKILLS.md|HEARTBEAT.md)',
        'section': 'string (optional markdown section title)',
      },
    ),
    'system.profile.update': const ToolDefinition(
      name: 'system.profile.update',
      description:
          'Update a specific User Identity/Profile field in the current agent workspace SOUL.md. Use for user name, nickname, timezone, role, language, and communication style.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'field':
            'string (required: name|nickname|preferred_language|timezone|work_role|main_project|communication_style|design_preference)',
        'value': 'string (required)',
      },
      operation: 'update',
      targetEntity: 'profile',
      selectorArgs: ['field'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'profile',
        expectedDataKeys: ['field'],
      ),
    ),
    'system.memory.append': const ToolDefinition(
      name: 'system.memory.append',
      description:
          'Append a concise long-term fact or preference to the current agent workspace MEMORY.md. Never store secrets.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'content': 'string (required)',
        'category':
            'string (optional: fact|preference|bookmark|session, default fact)',
      },
      operation: 'create',
      targetEntity: 'memory',
      selectorArgs: ['content'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'memory',
        expectedDataKeys: ['entry'],
      ),
    ),
    'system.agents.list': const ToolDefinition(
      name: 'system.agents.list',
      description: 'List all configured agents and their public provider info.',
      risk: 'safe',
      requiresConfirmation: false,
      operation: 'list',
      targetEntity: 'agent',
    ),
    'system.agents.create': const ToolDefinition(
      name: 'system.agents.create',
      description:
          'Create a new agent and generate its workspace markdown from the system standard template. Pass persona/role/description to bake the agent\u2019s personality into its SOUL.md in the same call.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'name': 'string (required)',
        'providerId':
            'string (optional if exactly one provider exists; otherwise required)',
        'maxContextLength': 'int (optional, default 8191)',
        'iconKey': 'string (optional)',
        'colorKey': 'string (optional)',
        'role':
            'string (optional, short role/title e.g. "Skillful coder agent")',
        'persona':
            'string (optional, 2-4 sentence personality description for SOUL.md Agent Identity)',
        'communicationStyle':
            'string (optional, e.g. "concise, technical, code-first")',
      },
      operation: 'create',
      targetEntity: 'agent',
      selectorArgs: ['name'],
      postconditions: {'agent_present': 'name'},
      verificationProbe: ToolVerificationProbe(
        kind: 'snapshot_contains',
        entityType: 'agent',
        expectPresent: true,
        selectorArgKey: 'name',
      ),
    ),
    'system.agents.delete': const ToolDefinition(
      name: 'system.agents.delete',
      description:
          'Delete an agent and its workspace. Cannot delete the current active agent from its own chat. ALWAYS pass `name` (preferred) and `id` together when known — names are user-visible and stable; ids are opaque hashes that may not match across mutating ops in the same multi-step task. The handler resolves by id first, then falls back to name (case-insensitive).',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'name':
            'string (preferred; case-insensitive match on the agent display name)',
        'id':
            'string (optional fallback; only reliable when produced by a system.agents.list call in the SAME planning round)',
      },
      operation: 'delete',
      targetEntity: 'agent',
      selectorArgs: ['id', 'agentId', 'name'],
      policies: ['deny_current_agent'],
      postconditions: {'agent_absent': 'name'},
      verificationProbe: ToolVerificationProbe(
        kind: 'snapshot_absent',
        entityType: 'agent',
        expectPresent: false,
        selectorArgKey: 'name',
      ),
    ),
    'system.providers.list': const ToolDefinition(
      name: 'system.providers.list',
      description:
          'List configured LLM providers with public fields only. API keys are never returned.',
      risk: 'safe',
      requiresConfirmation: false,
      operation: 'list',
      targetEntity: 'provider',
    ),
    'system.modules.list': const ToolDefinition(
      name: 'system.modules.list',
      description:
          'List available and installed modules, enabled state, and module setting toggles.',
      risk: 'safe',
      requiresConfirmation: false,
      operation: 'list',
      targetEntity: 'module',
    ),
    'system.tools.list': const ToolDefinition(
      name: 'system.tools.list',
      description:
          'List registered runtime tools, risk levels, confirmation requirements, and current module permission availability.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'system.modules.toggle': const ToolDefinition(
      name: 'system.modules.toggle',
      description:
          'Enable/disable an installed module or one of its setting toggles. Pass settingKey to flip a per-feature switch (e.g. allow_create on notes). Without settingKey, toggles the module-level enabled flag.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'moduleId': 'string (required, e.g. notes/files/calendar)',
        'settingKey':
            'string (optional, specific permission key from module settings)',
        'enabled':
            'bool (optional, explicit target state; if omitted, toggles current)',
      },
      operation: 'update',
      targetEntity: 'module',
      selectorArgs: ['moduleId', 'settingKey'],
    ),
    'system.agents.update': const ToolDefinition(
      name: 'system.agents.update',
      description:
          'Update an existing agent: rename, swap provider, change icon/color, or change context length. Pass id (preferred) or name to identify, then any combination of newName/providerId/maxContextLength/iconKey/colorKey.',
      risk: 'sensitive-lite',
      requiresConfirmation: true,
      inputSchema: {
        'id': 'string (preferred, agent id)',
        'name': 'string (fallback, agent name)',
        'newName': 'string (optional)',
        'providerId':
            'string (optional, provider id or nickname for re-binding)',
        'maxContextLength': 'int (optional)',
        'iconKey': 'string (optional)',
        'colorKey': 'string (optional)',
      },
      operation: 'update',
      targetEntity: 'agent',
      selectorArgs: ['id', 'name'],
    ),
    'system.export_all': const ToolDefinition(
      name: 'system.export_all',
      description:
          'Export a JSON snapshot of agents, providers (no API keys), and module settings. The result is returned in tool data; runtime caller can write it to a file via files.write for backup.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'system.import': const ToolDefinition(
      name: 'system.import',
      description:
          'Restore from a snapshot produced by system.export_all. Mode "merge" adds missing entries (default). Mode "replace" wipes existing agents (except current) and modules first. Provider API keys are NOT in snapshots and must be re-entered manually.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'snapshot': 'object (required, JSON output from system.export_all)',
        'mode': 'string (optional: merge | replace. default merge)',
      },
    ),

    // ── Chat ─────────────────────────────────────────────────────────────
    'chat.send': const ToolDefinition(
      name: 'chat.send',
      description:
          'Send a message from the agent into a chat UI as an assistant message. Use when user explicitly asks to "kirim ke chat", "send to chat", or to deliver a markdown-formatted result (summary, digest, report) as a chat bubble rather than just a notification. Content supports full markdown.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'content': 'string (required, markdown body of the message)',
        'agentId':
            'string (optional, target agent id; defaults to the current agent)',
      },
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
      descriptions.add(_formatToolDescription(def));
    }
    return descriptions;
  }

  /// Build formatted descriptions for a selected subset of tools.
  ///
  /// Unknown names are ignored so callers can safely pass policy-generated
  /// sets across app versions.
  List<String> buildToolDescriptions(Set<String> names) {
    final descriptions = <String>[];
    for (final def in _registry.values) {
      if (names.contains(def.name)) {
        descriptions.add(_formatToolDescription(def));
      }
    }
    return descriptions;
  }

  /// Slim format for the analyzer phase: just `name: description`.
  ///
  /// The analyzer only decides intent + whether tools are needed; it does not
  /// pick arguments or evaluate risk. Schema, risk, and confirmation metadata
  /// add tokens without changing analyzer accuracy, so we drop them here.
  /// Saves ~60% of the tool surface tokens for that phase.
  List<String> buildAnalyzerToolDescriptions(Set<String> names) {
    final descriptions = <String>[];
    for (final def in _registry.values) {
      if (names.contains(def.name)) {
        descriptions.add('- ${def.name}: ${def.description}');
      }
    }
    return descriptions;
  }

  /// Slim descriptions for every registered tool.
  List<String> buildAllAnalyzerToolDescriptions() {
    final descriptions = <String>[];
    for (final def in _registry.values) {
      descriptions.add('- ${def.name}: ${def.description}');
    }
    return descriptions;
  }

  String _formatToolDescription(ToolDefinition def) {
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
    return parts.toString();
  }

  /// Validate a tool call request against the registry.
  /// Returns null if valid, or an error message if invalid.
  String? validate(ToolCallRequest request) {
    if (!isRegistered(request.name)) {
      return 'Unknown tool: ${request.name}. Not registered.';
    }
    return null;
  }

  Future<ToolExecutionResult?> permissionDeniedResult(String toolName) {
    return ToolPermissionPolicy(moduleRepository).deniedResult(toolName);
  }

  /// Returns true when this is a `files.*` call whose target path lands
  /// OUTSIDE the calling agent's own workspace. The runtime escalates such
  /// calls to a confirmation gate even when the registered risk is `safe`,
  /// because reading/writing peer workspaces is sensitive by intent.
  ///
  /// For tools that don't operate on a path (or non-files.* tools) this
  /// returns false and the registry-level confirmation rule still applies.
  Future<bool> requiresCrossWorkspaceConfirmation(
    ToolCallRequest request,
  ) async {
    if (!request.name.startsWith('files.')) return false;
    final files = _filesTools();
    final candidatePaths = <String>[];
    final path = request.args['path'];
    if (path is String && path.trim().isNotEmpty) {
      candidatePaths.add(path.trim());
    }
    final from = request.args['from'];
    if (from is String && from.trim().isNotEmpty) {
      candidatePaths.add(from.trim());
    }
    final to = request.args['to'];
    if (to is String && to.trim().isNotEmpty) {
      candidatePaths.add(to.trim());
    }
    for (final p in candidatePaths) {
      if (await files.isCrossWorkspacePath(p)) return true;
    }
    return false;
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

    final denied = await permissionDeniedResult(request.name);
    if (denied != null) return denied;

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
    final denied = await permissionDeniedResult(request.name);
    if (denied != null) return denied;
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
      case 'notification.create_local':
        return _executeNotificationCreateLocal(request.args);
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
      case 'notes.pin':
        return _notesTools().executeSetPinned(request.args, pinned: true);
      case 'notes.unpin':
        return _notesTools().executeSetPinned(request.args, pinned: false);
      case 'notes.archive':
        return _notesTools().executeSetArchived(request.args, archived: true);
      case 'notes.unarchive':
        return _notesTools().executeSetArchived(request.args, archived: false);
      case 'notes.append':
        return _notesTools().executeAppend(request.args);
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
      case 'files.copy':
        return _filesTools().executeCopy(request.args);
      case 'files.append':
        return _filesTools().executeAppend(request.args);
      case 'files.metadata':
        return _filesTools().executeMetadata(request.args);
      case 'files.search':
        return _filesTools().executeSearch(request.args);
      case 'files.tree':
        return _filesTools().executeTree(request.args);
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
      case 'calendar.upcoming':
        return _calendarTools().executeUpcoming(request.args);
      case 'calendar.conflicts':
        return _calendarTools().executeConflicts(request.args);
      case 'calendar.free_slot':
        return _calendarTools().executeFreeSlot(request.args);
      case 'calendar.link_note':
        return _calendarTools().executeLinkNote(request.args);
      case 'workflow.create':
        return _workflowTools().create(
          agentId: agentId.isNotEmpty ? agentId : agentName,
          args: request.args,
        );
      case 'workflow.create_from_template':
        return _workflowTools().createFromTemplate(
          agentId: agentId.isNotEmpty ? agentId : agentName,
          args: request.args,
        );
      case 'workflow.list_templates':
        return _workflowTools().listTemplates();
      case 'workflow.list':
        return _workflowTools().list(
          callerAgentId: agentId.isNotEmpty ? agentId : agentName,
          args: request.args,
        );
      case 'workflow.read':
        return _workflowTools().read(args: request.args);
      case 'workflow.update':
        return _workflowTools().update(args: request.args);
      case 'workflow.delete':
        return _workflowTools().delete(args: request.args);
      case 'workflow.toggle':
        return _workflowTools().toggle(args: request.args);
      case 'system.self':
        return _systemTools().executeSelf();
      case 'system.workspace.schema':
        return _systemTools().executeWorkspaceSchema();
      case 'system.workspace.read':
        return _systemTools().executeWorkspaceRead(request.args);
      case 'system.profile.update':
        return _systemTools().executeProfileUpdate(request.args);
      case 'system.memory.append':
        return _systemTools().executeMemoryAppend(request.args);
      case 'system.agents.list':
        return _systemTools().executeAgentsList();
      case 'system.agents.create':
        return _systemTools().executeAgentsCreate(request.args);
      case 'system.agents.delete':
        return _systemTools().executeAgentsDelete(request.args);
      case 'system.providers.list':
        return _systemTools().executeProvidersList();
      case 'system.modules.list':
        return _systemTools().executeModulesList();
      case 'system.tools.list':
        return _systemTools().executeToolsList();
      case 'system.modules.toggle':
        return _systemTools().executeModulesToggle(request.args);
      case 'system.agents.update':
        return _systemTools().executeAgentsUpdate(request.args);
      case 'system.export_all':
        return _systemTools().executeExportAll();
      case 'system.import':
        return _systemTools().executeImport(request.args);
      case 'chat.send':
        return _executeChatSend(request.args);
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
    Map<String, dynamic> args,
  ) async {
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

  Future<ToolExecutionResult> _executeAppResolve(
    Map<String, dynamic> args,
  ) async {
    try {
      final query = (args['query'] as String? ?? args['name'] as String? ?? '')
          .trim();
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
        data: {'query': query, 'matched': true, 'app': result.toJson()},
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
      final friendlyName =
          (args['name'] as String? ?? args['query'] as String? ?? '').trim();

      if (pkg.isEmpty && friendlyName.isNotEmpty) {
        final result = await AppAliasResolver.resolve(friendlyName);
        if (result != null && result.confidence >= 0.85) {
          pkg = result.packageName;
        } else if (result != null) {
          // Below high-confidence threshold — surface alternatives.
          return ToolExecutionResult(
            success: false,
            toolName: 'app.open',
            data: {'matched': result.toJson(), 'low_confidence': true},
            error:
                'Low confidence match (${result.confidence.toStringAsFixed(2)}) for "$friendlyName". Best guess: ${result.name}. Use app.resolve and ask user to confirm.',
          );
        }
      }

      if (pkg.isEmpty) {
        return ToolExecutionResult(
          success: false,
          toolName: 'app.open',
          error:
              'Could not resolve app. Call app.resolve first to get the package name.',
        );
      }

      final success =
          await _appChannel.invokeMethod<bool>('openApp', {'package': pkg}) ??
          false;
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
      final apps =
          raw?.map((e) => Map<String, String>.from(e as Map)).toList() ?? [];
      return ToolExecutionResult(
        success: true,
        toolName: 'app.list_installed',
        data: {'apps': apps, 'count': apps.length},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app.list_installed',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeOpenSettings(
    Map<String, dynamic> args,
  ) async {
    try {
      final action = args['action'] as String? ?? 'android.settings.SETTINGS';
      await _appChannel.invokeMethod<bool>('openSettings', {'action': action});
      return ToolExecutionResult(
        success: true,
        toolName: 'settings.open',
        data: {'action': action},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'settings.open',
        error: e.toString(),
      );
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
      final success =
          await _appChannel.invokeMethod<bool>('openUrl', {'url': url}) ??
          false;
      return ToolExecutionResult(
        success: success,
        toolName: 'intent.open_url',
        data: {'url': url, 'opened': success},
        error: success ? null : 'Failed to open URL: $url',
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'intent.open_url',
        error: e.toString(),
      );
    }
  }

  // ── Device Context helpers ───────────────────────────────────────────

  DeviceContextRepository _deviceRepo() => DeviceContextRepository(
    service: DeviceContextService(),
    moduleRepository: moduleRepository,
  );

  NotesTools _notesTools() => NotesTools(moduleRepository: moduleRepository);

  FilesTools _filesTools() =>
      FilesTools(agentName: agentName, moduleRepository: moduleRepository);

  CalendarTools _calendarTools() =>
      CalendarTools(moduleRepository: moduleRepository);

  WorkflowTools _workflowTools() => WorkflowTools(
    moduleRepository: moduleRepository,
    agentRepository: agentRepository,
  );

  SystemTools _systemTools() => SystemTools(
    agentId: agentId,
    agentName: agentName,
    moduleRepository: moduleRepository,
    agentRepository: agentRepository,
    providerRepository: providerRepository,
    saveAgent: saveAgent,
    deleteAgent: deleteAgent,
    toolDefinitions: _registry.values,
  );

  Future<ToolExecutionResult> _executeDeviceBattery() async {
    try {
      final repo = _deviceRepo();
      final info = await repo.getBattery();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.battery',
          error:
              'Device Context module is disabled or battery info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.battery',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.battery',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeDeviceNetwork() async {
    try {
      final info = await _deviceRepo().getNetwork();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.network',
          error:
              'Device Context module is disabled or network info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.network',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.network',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeDeviceStorage() async {
    try {
      final info = await _deviceRepo().getStorage();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.storage',
          error:
              'Device Context module is disabled or storage info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.storage',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.storage',
        error: e.toString(),
      );
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
      return ToolExecutionResult(
        success: true,
        toolName: 'device.time',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.time',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeDeviceLocale() async {
    try {
      final info = await _deviceRepo().getLocale();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.locale',
          error:
              'Device Context module is disabled or locale info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.locale',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.locale',
        error: e.toString(),
      );
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
      return ToolExecutionResult(
        success: false,
        toolName: 'device.summary',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeDeviceForegroundApp() async {
    try {
      final info = await _deviceRepo().getForegroundApp();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.foreground_app',
          error:
              'Device Context module is disabled or foreground app detection not allowed.',
        );
      }
      return ToolExecutionResult(
        success: info.available,
        toolName: 'device.foreground_app',
        data: info.toJson(),
        error: info.available
            ? null
            : 'Foreground app unavailable: ${info.reason}',
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.foreground_app',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeDeviceUsageStats(
    Map<String, dynamic> args,
  ) async {
    try {
      final days = (args['days'] as num?)?.toInt() ?? 7;
      final result = await _deviceRepo().getUsageStats(days: days);
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.usage_stats',
          error:
              'Device Context module is disabled or foreground app permission not granted.',
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
      return ToolExecutionResult(
        success: false,
        toolName: 'device.usage_stats',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeDeviceCharging() async {
    try {
      final info = await _deviceRepo().getCharging();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.charging',
          error:
              'Device Context module is disabled or charging info not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.charging',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.charging',
        error: e.toString(),
      );
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
      return ToolExecutionResult(
        success: false,
        toolName: 'device.dnd',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeDeviceBluetooth() async {
    try {
      final info = await _deviceRepo().getBluetooth();
      if (info == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.bluetooth',
          error:
              'Device Context module is disabled or Bluetooth status not allowed.',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'device.bluetooth',
        data: info.toJson(),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'device.bluetooth',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeDeviceDndSet(
    Map<String, dynamic> args,
  ) async {
    try {
      final enabled = args['enabled'] as bool? ?? false;
      final mode = args['mode'] as String?;
      final result = await _deviceRepo().setDnd(enabled: enabled, mode: mode);
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.dnd.set',
          error:
              'Device Context module is disabled or DND control not allowed.',
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
      return ToolExecutionResult(
        success: false,
        toolName: 'device.dnd.set',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeDeviceWifiReconnect() async {
    try {
      final result = await _deviceRepo().reconnectWifi();
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.wifi.reconnect',
          error:
              'Device Context module is disabled or network control not allowed.',
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
      return ToolExecutionResult(
        success: false,
        toolName: 'device.wifi.reconnect',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeDeviceBluetoothSet(
    Map<String, dynamic> args,
  ) async {
    try {
      final enabled = args['enabled'] as bool? ?? false;
      final result = await _deviceRepo().setBluetoothEnabled(enabled: enabled);
      if (result == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'device.bluetooth.set',
          error:
              'Device Context module is disabled or Bluetooth control not allowed.',
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
      return ToolExecutionResult(
        success: false,
        toolName: 'device.bluetooth.set',
        error: e.toString(),
      );
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
      return ToolExecutionResult(
        success: false,
        toolName: 'device.wifi',
        error: e.toString(),
      );
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
      return ToolExecutionResult(
        success: false,
        toolName: 'device.cellular',
        error: e.toString(),
      );
    }
  }

  // ── Notification Intelligence helpers ─────────────────────────────────

  NotificationRepository _notifRepo() => NotificationRepository(
    service: NotificationService(),
    moduleRepository: moduleRepository,
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
      final success =
          await channel.invokeMethod<bool>('openApp', {'package': pkg}) ??
          false;
      return ToolExecutionResult(
        success: success,
        toolName: 'notification.open_app',
        data: {'package': pkg, 'appName': res.data!.appName, 'opened': success},
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

  Future<ToolExecutionResult> _executeChatSend(
    Map<String, dynamic> args,
  ) async {
    try {
      final content = (args['content'] ?? '').toString().trim();
      if (content.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'chat.send',
          error: 'Missing required field: content.',
        );
      }

      // Resolve target agent. Falls back to the current router agent so the
      // common case ("send this summary to my chat") works without the LLM
      // having to look up an id first.
      final rawTarget = (args['agentId'] ?? '').toString().trim();
      final targetAgentId = rawTarget.isNotEmpty
          ? rawTarget
          : (agentId.isNotEmpty ? agentId : agentName);

      if (targetAgentId.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'chat.send',
          error: 'No target agent resolved for chat.send.',
        );
      }

      final service = ChatHistoryService();
      final messageId = await service.addMessage(
        targetAgentId,
        ChatMessage(role: 'assistant', content: content),
      );

      // Bump unread badge unless the user is currently viewing that chat
      // (UnreadService internally skips active agents).
      await UnreadService.instance.increment(targetAgentId);

      return ToolExecutionResult(
        success: true,
        toolName: 'chat.send',
        data: {
          'agentId': targetAgentId,
          'messageId': messageId,
          'length': content.length,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'chat.send',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeNotificationCreateLocal(
    Map<String, dynamic> args,
  ) async {
    try {
      final title = (args['title'] ?? '').toString().trim();
      final body = (args['body'] ?? '').toString().trim();
      if (title.isEmpty || body.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notification.create_local',
          error: 'title and body are required.',
        );
      }
      final styleRaw = (args['style'] ?? 'normal').toString().toLowerCase();
      final style =
          (styleRaw == 'silent' || styleRaw == 'normal' || styleRaw == 'alarm')
          ? styleRaw
          : 'normal';
      final id = await AgentNotificationService.showNow(
        title: title,
        body: body,
        style: style,
      );
      return ToolExecutionResult(
        success: true,
        toolName: 'notification.create_local',
        data: {'notificationId': id, 'title': title, 'style': style},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.create_local',
        error: e.toString(),
      );
    }
  }
}
