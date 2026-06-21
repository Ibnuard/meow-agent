import '../permission/permission_manager.dart';
import 'tool_permission_policy.dart';

/// Static permission requirement map for Meow Agent tools.
///
/// Each entry maps a tool name to its [ToolPermissionRequirement]:
/// which module must be installed/enabled, and optionally which setting
/// toggle must be on. Generated from module plugin metadata.
///
/// Extracted from [ToolPermissionPolicy] to keep the policy class focused
/// on runtime checks rather than data declaration.
const toolPermissionRequirements = <String, ToolPermissionRequirement>{
  'clipboard.read': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_clipboard_read',
    settingLabel: 'Read Clipboard',
    actionLabel: 'read the clipboard',
  ),
  'clipboard.write': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_clipboard_write',
    settingLabel: 'Update Clipboard',
    actionLabel: 'write to the clipboard',
  ),
  'app.resolve': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_open_apps',
    settingLabel: 'Open Installed Apps',
    actionLabel: 'find installed apps',
  ),
  'app.open': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_open_apps',
    settingLabel: 'Open Installed Apps',
    actionLabel: 'open apps',
  ),
  'app.list_installed': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_open_apps',
    settingLabel: 'Open Installed Apps',
    actionLabel: 'list installed apps',
  ),
  'settings.open': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_open_apps',
    settingLabel: 'Open Installed Apps',
    actionLabel: 'open Android settings',
  ),
  'intent.open_url': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_open_apps',
    settingLabel: 'Open Installed Apps',
    actionLabel: 'open URLs',
  ),
  'device.battery': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_battery',
    settingLabel: 'Battery Info',
    actionLabel: 'read battery info',
  ),
  'device.network': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_network',
    settingLabel: 'Network Info',
    actionLabel: 'read network info',
  ),
  'device.storage': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_storage',
    settingLabel: 'Storage Info',
    actionLabel: 'read storage info',
  ),
  'device.time': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_time_locale',
    settingLabel: 'Time & Locale',
    actionLabel: 'read local time',
  ),
  'device.locale': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_time_locale',
    settingLabel: 'Time & Locale',
    actionLabel: 'read locale info',
  ),
  'device.summary': ToolPermissionRequirement(
    moduleId: 'device_context',
    actionLabel: 'read device context',
  ),
  'device.foreground_app': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_foreground_app',
    settingLabel: 'Foreground App Detection',
    actionLabel: 'detect the foreground app',
  ),
  'device.usage_stats': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_foreground_app',
    settingLabel: 'Foreground App Detection',
    actionLabel: 'read app usage stats',
  ),
  'device.charging': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_charging',
    settingLabel: 'Charging Info',
    actionLabel: 'read charging info',
  ),
  'device.dnd': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_dnd',
    settingLabel: 'Do Not Disturb Status',
    actionLabel: 'read Do Not Disturb status',
  ),
  'device.bluetooth': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_bluetooth',
    settingLabel: 'Bluetooth Status',
    actionLabel: 'read Bluetooth status',
    androidPermission: PermissionType.bluetoothConnect,
  ),
  'device.dnd.set': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_dnd',
    settingLabel: 'Do Not Disturb Status',
    actionLabel: 'change Do Not Disturb',
  ),
  'device.wifi.reconnect': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_network',
    settingLabel: 'Network Info',
    actionLabel: 'reconnect WiFi',
  ),
  'device.bluetooth.set': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_bluetooth',
    settingLabel: 'Bluetooth Status',
    actionLabel: 'change Bluetooth',
    androidPermission: PermissionType.bluetoothConnect,
  ),
  'device.wifi': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_network',
    settingLabel: 'Network Info',
    actionLabel: 'read WiFi status',
  ),
  'device.cellular': ToolPermissionRequirement(
    moduleId: 'device_context',
    settingKey: 'allow_network',
    settingLabel: 'Network Info',
    actionLabel: 'read cellular status',
  ),
  'notification.status': ToolPermissionRequirement(
    moduleId: 'notification_intelligence',
    settingKey: 'allow_read',
    settingLabel: 'Read Notifications',
    actionLabel: 'check notification access',
  ),
  'notification.read_recent': ToolPermissionRequirement(
    moduleId: 'notification_intelligence',
    settingKey: 'allow_read',
    settingLabel: 'Read Notifications',
    actionLabel: 'read notifications',
  ),
  'notification.summarize': ToolPermissionRequirement(
    moduleId: 'notification_intelligence',
    settingKey: 'allow_read',
    settingLabel: 'Read Notifications',
    actionLabel: 'summarize notifications',
  ),
  'notification.classify': ToolPermissionRequirement(
    moduleId: 'notification_intelligence',
    settingKey: 'allow_read',
    settingLabel: 'Read Notifications',
    actionLabel: 'classify notifications',
  ),
  'notification.reply_suggestion': ToolPermissionRequirement(
    moduleId: 'notification_intelligence',
    settingKey: 'allow_reply',
    settingLabel: 'Reply to Notifications',
    actionLabel: 'suggest notification replies',
  ),
  'notification.reply': ToolPermissionRequirement(
    moduleId: 'notification_intelligence',
    settingKey: 'allow_reply',
    settingLabel: 'Reply to Notifications',
    actionLabel: 'reply to notifications directly',
  ),
  'notification.open_app': ToolPermissionRequirement(
    moduleId: 'notification_intelligence',
    settingKey: 'allow_read',
    settingLabel: 'Read Notifications',
    actionLabel: 'open the notification source app',
  ),
  'notification.create_local': ToolPermissionRequirement(
    moduleId: 'notification_intelligence',
    settingKey: 'allow_read',
    settingLabel: 'Read Notifications',
    actionLabel: 'push a local notification',
    androidPermission: PermissionType.notification,
  ),
  'notes.create': ToolPermissionRequirement(
    moduleId: 'notes',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Notes',
    actionLabel: 'create notes',
    androidPermission: PermissionType.storage,
  ),
  'notes.list_recent': ToolPermissionRequirement(
    moduleId: 'notes',
    settingKey: 'allow_read',
    settingLabel: 'Allow Read Notes',
    actionLabel: 'list notes',
    androidPermission: PermissionType.storage,
  ),
  'notes.read': ToolPermissionRequirement(
    moduleId: 'notes',
    settingKey: 'allow_read',
    settingLabel: 'Allow Read Notes',
    actionLabel: 'read notes',
    androidPermission: PermissionType.storage,
  ),
  'notes.search': ToolPermissionRequirement(
    moduleId: 'notes',
    settingKey: 'allow_search',
    settingLabel: 'Allow Search Notes',
    actionLabel: 'search notes',
    androidPermission: PermissionType.storage,
  ),
  'notes.update': ToolPermissionRequirement(
    moduleId: 'notes',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Notes',
    actionLabel: 'update notes',
    androidPermission: PermissionType.storage,
  ),
  'notes.delete': ToolPermissionRequirement(
    moduleId: 'notes',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Notes',
    actionLabel: 'delete notes',
    androidPermission: PermissionType.storage,
  ),
  'notes.export': ToolPermissionRequirement(
    moduleId: 'notes',
    settingKey: 'allow_read',
    settingLabel: 'Allow Read Notes',
    actionLabel: 'export notes',
    androidPermission: PermissionType.storage,
  ),
  'notes.append': ToolPermissionRequirement(
    moduleId: 'notes',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Notes',
    actionLabel: 'append to notes',
    androidPermission: PermissionType.storage,
  ),
  'notes.pin': ToolPermissionRequirement(
    moduleId: 'notes',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Notes',
    actionLabel: 'pin notes',
    androidPermission: PermissionType.storage,
  ),
  'notes.unpin': ToolPermissionRequirement(
    moduleId: 'notes',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Notes',
    actionLabel: 'unpin notes',
    androidPermission: PermissionType.storage,
  ),
  'notes.archive': ToolPermissionRequirement(
    moduleId: 'notes',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Notes',
    actionLabel: 'archive notes',
    androidPermission: PermissionType.storage,
  ),
  'notes.unarchive': ToolPermissionRequirement(
    moduleId: 'notes',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Notes',
    actionLabel: 'unarchive notes',
    androidPermission: PermissionType.storage,
  ),
  'files.create': ToolPermissionRequirement(
    moduleId: 'files',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Files',
    actionLabel: 'create files',
    androidPermission: PermissionType.storage,
  ),
  'files.read': ToolPermissionRequirement(
    moduleId: 'files',
    settingKey: 'allow_read',
    settingLabel: 'Allow Read Files',
    actionLabel: 'read files',
    androidPermission: PermissionType.storage,
  ),
  'files.write': ToolPermissionRequirement(
    moduleId: 'files',
    settingKey: 'allow_write',
    settingLabel: 'Allow Write Files',
    actionLabel: 'write files',
    androidPermission: PermissionType.storage,
  ),
  'files.delete': ToolPermissionRequirement(
    moduleId: 'files',
    settingKey: 'allow_delete',
    settingLabel: 'Allow Delete Files',
    actionLabel: 'delete files',
    androidPermission: PermissionType.storage,
  ),
  'files.list': ToolPermissionRequirement(
    moduleId: 'files',
    settingKey: 'allow_read',
    settingLabel: 'Allow Read Files',
    actionLabel: 'list files',
    androidPermission: PermissionType.storage,
  ),
  'files.move': ToolPermissionRequirement(
    moduleId: 'files',
    settingKey: 'allow_organize',
    settingLabel: 'Allow Organize Files',
    actionLabel: 'move files',
    androidPermission: PermissionType.storage,
  ),
  'files.mkdir': ToolPermissionRequirement(
    moduleId: 'files',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Files',
    actionLabel: 'create folders',
    androidPermission: PermissionType.storage,
  ),
  'files.copy': ToolPermissionRequirement(
    moduleId: 'files',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Files',
    actionLabel: 'copy files',
    androidPermission: PermissionType.storage,
  ),
  'files.append': ToolPermissionRequirement(
    moduleId: 'files',
    settingKey: 'allow_write',
    settingLabel: 'Allow Write Files',
    actionLabel: 'append to files',
    androidPermission: PermissionType.storage,
  ),
  'calendar.create': ToolPermissionRequirement(
    moduleId: 'calendar',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Events',
    actionLabel: 'create calendar events',
  ),
  'calendar.today': ToolPermissionRequirement(
    moduleId: 'calendar',
    settingKey: 'allow_read',
    settingLabel: 'Allow Read Events',
    actionLabel: 'read calendar events',
  ),
  'calendar.list': ToolPermissionRequirement(
    moduleId: 'calendar',
    settingKey: 'allow_read',
    settingLabel: 'Allow Read Events',
    actionLabel: 'list calendar events',
  ),
  'calendar.read': ToolPermissionRequirement(
    moduleId: 'calendar',
    settingKey: 'allow_read',
    settingLabel: 'Allow Read Events',
    actionLabel: 'read calendar events',
  ),
  'calendar.update': ToolPermissionRequirement(
    moduleId: 'calendar',
    settingKey: 'allow_update',
    settingLabel: 'Allow Update Events',
    actionLabel: 'update calendar events',
  ),
  'calendar.delete': ToolPermissionRequirement(
    moduleId: 'calendar',
    settingKey: 'allow_delete',
    settingLabel: 'Allow Delete Events',
    actionLabel: 'delete calendar events',
  ),
  'calendar.link_note': ToolPermissionRequirement(
    moduleId: 'calendar',
    settingKey: 'allow_update',
    settingLabel: 'Allow Update Events',
    actionLabel: 'link a note to a calendar event',
  ),
  'workflow.create': ToolPermissionRequirement(
    moduleId: 'workflows',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Workflows',
    actionLabel: 'create workflows',
  ),
  'workflow.create_from_template': ToolPermissionRequirement(
    moduleId: 'workflows',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Workflows',
    actionLabel: 'create workflows',
  ),
  'workflow.list_templates': ToolPermissionRequirement(
    moduleId: 'workflows',
    settingKey: 'allow_read',
    settingLabel: 'Allow Read Workflows',
    actionLabel: 'list workflow templates',
  ),
  'workflow.list': ToolPermissionRequirement(
    moduleId: 'workflows',
    settingKey: 'allow_read',
    settingLabel: 'Allow Read Workflows',
    actionLabel: 'list workflows',
  ),
  'workflow.read': ToolPermissionRequirement(
    moduleId: 'workflows',
    settingKey: 'allow_read',
    settingLabel: 'Allow Read Workflows',
    actionLabel: 'read workflows',
  ),
  'workflow.update': ToolPermissionRequirement(
    moduleId: 'workflows',
    settingKey: 'allow_update',
    settingLabel: 'Allow Update Workflows',
    actionLabel: 'update workflows',
  ),
  'workflow.delete': ToolPermissionRequirement(
    moduleId: 'workflows',
    settingKey: 'allow_delete',
    settingLabel: 'Allow Delete Workflows',
    actionLabel: 'delete workflows',
  ),
  'workflow.toggle': ToolPermissionRequirement(
    moduleId: 'workflows',
    settingKey: 'allow_update',
    settingLabel: 'Allow Update Workflows',
    actionLabel: 'enable or disable workflows',
  ),
  // ─── Web / API Store module ─────────────────────────────────────────────
  'web.fetch': ToolPermissionRequirement(
    moduleId: 'web',
    settingKey: 'allow_fetch',
    settingLabel: 'Fetch URL',
    actionLabel: 'make HTTP requests',
  ),
  'web.api.list': ToolPermissionRequirement(
    moduleId: 'web',
    settingKey: 'allow_call',
    settingLabel: 'Call APIs',
    actionLabel: 'list registered APIs',
  ),
  'web.api.call': ToolPermissionRequirement(
    moduleId: 'web',
    settingKey: 'allow_call',
    settingLabel: 'Call APIs',
    actionLabel: 'call registered APIs',
  ),
  'web.api.register': ToolPermissionRequirement(
    moduleId: 'web',
    settingKey: 'allow_register',
    settingLabel: 'Register APIs',
    actionLabel: 'register new APIs',
  ),
  'web.api.remove': ToolPermissionRequirement(
    moduleId: 'web',
    settingKey: 'allow_remove',
    settingLabel: 'Remove APIs',
    actionLabel: 'remove registered APIs',
  ),

  // ─── Database module ────────────────────────────────────────────────────
  'db.list_tables': ToolPermissionRequirement(
    moduleId: 'database',
    settingKey: 'allow_read',
    settingLabel: 'Read Tables',
    actionLabel: 'list database tables',
  ),
  'db.describe_table': ToolPermissionRequirement(
    moduleId: 'database',
    settingKey: 'allow_read',
    settingLabel: 'Read Tables',
    actionLabel: 'view table schema',
  ),
  'db.create_table': ToolPermissionRequirement(
    moduleId: 'database',
    settingKey: 'allow_create_table',
    settingLabel: 'Create Tables',
    actionLabel: 'create database tables',
  ),
  'db.drop_table': ToolPermissionRequirement(
    moduleId: 'database',
    settingKey: 'allow_drop_table',
    settingLabel: 'Drop Tables',
    actionLabel: 'drop database tables',
  ),
  'db.insert': ToolPermissionRequirement(
    moduleId: 'database',
    settingKey: 'allow_write',
    settingLabel: 'Write Database',
    actionLabel: 'insert database records',
  ),
  'db.query': ToolPermissionRequirement(
    moduleId: 'database',
    settingKey: 'allow_read',
    settingLabel: 'Read Tables',
    actionLabel: 'query database tables',
  ),
  'db.update': ToolPermissionRequirement(
    moduleId: 'database',
    settingKey: 'allow_write',
    settingLabel: 'Write Database',
    actionLabel: 'update database records',
  ),
  'db.delete': ToolPermissionRequirement(
    moduleId: 'database',
    settingKey: 'allow_write',
    settingLabel: 'Write Database',
    actionLabel: 'delete database records',
  ),

  // ─── Mini App module ───────────────────────────────────────────────────
  'miniapp.list': ToolPermissionRequirement(
    moduleId: 'miniapp',
    settingKey: 'allow_read',
    settingLabel: 'Allow Read Mini Apps',
    actionLabel: 'list installed mini apps',
  ),
  'miniapp.read': ToolPermissionRequirement(
    moduleId: 'miniapp',
    settingKey: 'allow_read',
    settingLabel: 'Allow Read Mini Apps',
    actionLabel: 'read mini app code',
  ),
  'miniapp.create': ToolPermissionRequirement(
    moduleId: 'miniapp',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Mini Apps',
    actionLabel: 'create or update mini apps',
  ),
  'miniapp.patch': ToolPermissionRequirement(
    moduleId: 'miniapp',
    settingKey: 'allow_create',
    settingLabel: 'Allow Create Mini Apps',
    actionLabel: 'patch mini app code',
  ),
  'miniapp.delete': ToolPermissionRequirement(
    moduleId: 'miniapp',
    settingKey: 'allow_delete',
    settingLabel: 'Allow Delete Mini Apps',
    actionLabel: 'delete mini apps',
  ),

  // ─── Communication module ──────────────────────────────────────────────
  'communication.resolve_contact': ToolPermissionRequirement(
    moduleId: 'communication',
    settingKey: 'contact_access',
    settingLabel: 'Contact Access',
    actionLabel: 'resolve contacts',
    androidPermission: PermissionType.contacts,
  ),
  'communication.list_contacts': ToolPermissionRequirement(
    moduleId: 'communication',
    settingKey: 'contact_access',
    settingLabel: 'Contact Access',
    actionLabel: 'list contacts',
    androidPermission: PermissionType.contacts,
  ),
  'communication.call': ToolPermissionRequirement(
    moduleId: 'communication',
    settingKey: 'call_enabled',
    settingLabel: 'Phone Calls',
    actionLabel: 'make phone calls',
    androidPermission: PermissionType.callPhone,
  ),
  'communication.send_sms': ToolPermissionRequirement(
    moduleId: 'communication',
    settingKey: 'sms_enabled',
    settingLabel: 'SMS',
    actionLabel: 'send SMS messages',
    androidPermission: PermissionType.sendSms,
  ),

  /*
  // VM module: agent surface is intentionally narrow. Safe reads are ungated;
  // command/server process control is gated behind Run Command.
  'vm.status': ToolPermissionRequirement(
    moduleId: 'vm',
    actionLabel: 'read VM runtime status',
  ),
  'vm.list_plugins': ToolPermissionRequirement(
    moduleId: 'vm',
    actionLabel: 'list VM runtime plugins',
  ),
  'vm.run_command': ToolPermissionRequirement(
    moduleId: 'vm',
    settingKey: 'allow_run_command',
    settingLabel: 'Run Command',
    actionLabel: 'run commands in the VM runtime',
  ),
  'vm.start_server': ToolPermissionRequirement(
    moduleId: 'vm',
    settingKey: 'allow_run_command',
    settingLabel: 'Run Command',
    actionLabel: 'start server processes in the VM runtime',
  ),
  'vm.stop_server': ToolPermissionRequirement(
    moduleId: 'vm',
    settingKey: 'allow_run_command',
    settingLabel: 'Run Command',
    actionLabel: 'stop server processes in the VM runtime',
  ),
  'vm.list_servers': ToolPermissionRequirement(
    moduleId: 'vm',
    actionLabel: 'list running VM servers',
  ),
  'vm.write_file': ToolPermissionRequirement(
    moduleId: 'vm',
    settingKey: 'allow_run_command',
    settingLabel: 'Run Command',
    actionLabel: 'write files into the VM workspace',
  ),
  'vm.export': ToolPermissionRequirement(
    moduleId: 'vm',
    settingKey: 'allow_run_command',
    settingLabel: 'Run Command',
    actionLabel: 'export the VM workspace to shared storage',
  ),
  */
};

/// Prefix-based requirement rules, checked by [ToolPermissionPolicy] AFTER an
/// exact-name lookup misses. A tool whose name starts with the key is gated by
/// the value.
const toolPermissionPrefixRequirements = <String, ToolPermissionRequirement>{};
