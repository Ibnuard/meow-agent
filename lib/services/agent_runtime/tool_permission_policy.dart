import '../../features/modules/data/module_model.dart';
import '../../features/modules/data/module_repository.dart';
import 'runtime_models.dart';

enum ToolPermissionBlockReason {
  moduleMissing,
  moduleDisabled,
  settingDisabled,
}

class ToolPermissionRequirement {
  const ToolPermissionRequirement({
    required this.moduleId,
    required this.actionLabel,
    required this.actionLabelId,
    this.settingKey,
    this.settingLabel,
    this.settingLabelId,
  });

  final String moduleId;
  final String actionLabel;
  final String actionLabelId;
  final String? settingKey;
  final String? settingLabel;
  final String? settingLabelId;
}

class ToolPermissionCheck {
  const ToolPermissionCheck.allowed()
    : allowed = true,
      requirement = null,
      reason = null,
      module = null,
      moduleSpec = null;

  const ToolPermissionCheck.blocked({
    required this.requirement,
    required this.reason,
    required this.moduleSpec,
    this.module,
  }) : allowed = false;

  final bool allowed;
  final ToolPermissionRequirement? requirement;
  final ToolPermissionBlockReason? reason;
  final ModuleModel? module;
  final ModuleModel? moduleSpec;

  String get moduleName => moduleSpec?.name ?? requirement?.moduleId ?? '';

  Map<String, dynamic> toData() {
    final req = requirement;
    return {
      'errorCode': ToolPermissionPolicy.permissionDeniedCode,
      'reason': reason?.name,
      'moduleId': req?.moduleId,
      'moduleName': moduleName,
      'settingKey': req?.settingKey,
      'settingLabel': req?.settingLabel,
      'settingLabelId': req?.settingLabelId,
      'actionLabel': req?.actionLabel,
      'actionLabelId': req?.actionLabelId,
    };
  }

  String toErrorMessage() {
    final req = requirement;
    final reasonName = reason?.name ?? 'unknown';
    final setting = req?.settingLabel;
    final settingPart = setting == null ? '' : ' Setting: "$setting".';
    return '${ToolPermissionPolicy.permissionDeniedCode}: $reasonName. '
        'Module: "$moduleName".$settingPart '
        'Enable the module or permission first.';
  }
}

class ToolPermissionPolicy {
  ToolPermissionPolicy(this._moduleRepository);

  static const permissionDeniedCode = 'module_permission_denied';

  final ModuleRepository _moduleRepository;

  Future<ToolPermissionCheck> check(String toolName) async {
    final req = _requirements[toolName];
    if (req == null) return const ToolPermissionCheck.allowed();

    final modules = await _moduleRepository.getInstalled();
    final module = modules.where((m) => m.id == req.moduleId).firstOrNull;
    final spec = ModuleRegistry.available
        .where((m) => m.id == req.moduleId)
        .firstOrNull;

    if (module == null) {
      return ToolPermissionCheck.blocked(
        requirement: req,
        reason: ToolPermissionBlockReason.moduleMissing,
        moduleSpec: spec,
      );
    }
    if (!module.enabled) {
      return ToolPermissionCheck.blocked(
        requirement: req,
        reason: ToolPermissionBlockReason.moduleDisabled,
        module: module,
        moduleSpec: spec ?? module,
      );
    }

    final settingKey = req.settingKey;
    if (settingKey != null && module.settings[settingKey] != true) {
      return ToolPermissionCheck.blocked(
        requirement: req,
        reason: ToolPermissionBlockReason.settingDisabled,
        module: module,
        moduleSpec: spec ?? module,
      );
    }

    return const ToolPermissionCheck.allowed();
  }

  Future<ToolExecutionResult?> deniedResult(String toolName) async {
    final result = await check(toolName);
    if (result.allowed) return null;
    return ToolExecutionResult(
      success: false,
      toolName: toolName,
      data: result.toData(),
      error: result.toErrorMessage(),
    );
  }

  static const Map<String, ToolPermissionRequirement> _requirements = {
    'clipboard.read': ToolPermissionRequirement(
      moduleId: 'clipboard_ai',
      actionLabel: 'read the clipboard',
      actionLabelId: 'membaca clipboard',
    ),
    'clipboard.write': ToolPermissionRequirement(
      moduleId: 'clipboard_ai',
      actionLabel: 'write to the clipboard',
      actionLabelId: 'menulis ke clipboard',
    ),
    'app.resolve': ToolPermissionRequirement(
      moduleId: 'app_control',
      actionLabel: 'find installed apps',
      actionLabelId: 'mencari aplikasi terinstal',
    ),
    'app.open': ToolPermissionRequirement(
      moduleId: 'app_control',
      actionLabel: 'open apps',
      actionLabelId: 'membuka aplikasi',
    ),
    'app.list_installed': ToolPermissionRequirement(
      moduleId: 'app_control',
      actionLabel: 'list installed apps',
      actionLabelId: 'melihat daftar aplikasi terinstal',
    ),
    'settings.open': ToolPermissionRequirement(
      moduleId: 'app_control',
      settingKey: 'allow_system_settings',
      settingLabel: 'Allow System Settings',
      settingLabelId: 'Izinkan Pengaturan Sistem',
      actionLabel: 'open Android settings',
      actionLabelId: 'membuka pengaturan Android',
    ),
    'intent.open_url': ToolPermissionRequirement(
      moduleId: 'app_control',
      settingKey: 'allow_url_intents',
      settingLabel: 'Allow URL Intents',
      settingLabelId: 'Izinkan Buka URL',
      actionLabel: 'open URLs',
      actionLabelId: 'membuka URL',
    ),
    'device.battery': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_battery',
      settingLabel: 'Battery Info',
      settingLabelId: 'Info Baterai',
      actionLabel: 'read battery info',
      actionLabelId: 'membaca info baterai',
    ),
    'device.network': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_network',
      settingLabel: 'Network Info',
      settingLabelId: 'Info Jaringan',
      actionLabel: 'read network info',
      actionLabelId: 'membaca info jaringan',
    ),
    'device.storage': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_storage',
      settingLabel: 'Storage Info',
      settingLabelId: 'Info Penyimpanan',
      actionLabel: 'read storage info',
      actionLabelId: 'membaca info penyimpanan',
    ),
    'device.time': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_time_locale',
      settingLabel: 'Time & Locale',
      settingLabelId: 'Waktu & Lokal',
      actionLabel: 'read local time',
      actionLabelId: 'membaca waktu lokal',
    ),
    'device.locale': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_time_locale',
      settingLabel: 'Time & Locale',
      settingLabelId: 'Waktu & Lokal',
      actionLabel: 'read locale info',
      actionLabelId: 'membaca info lokal',
    ),
    'device.summary': ToolPermissionRequirement(
      moduleId: 'device_context',
      actionLabel: 'read device context',
      actionLabelId: 'membaca konteks perangkat',
    ),
    'device.foreground_app': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_foreground_app',
      settingLabel: 'Foreground App Detection',
      settingLabelId: 'Deteksi Aplikasi Aktif',
      actionLabel: 'detect the foreground app',
      actionLabelId: 'mendeteksi aplikasi aktif',
    ),
    'device.usage_stats': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_foreground_app',
      settingLabel: 'Foreground App Detection',
      settingLabelId: 'Deteksi Aplikasi Aktif',
      actionLabel: 'read app usage stats',
      actionLabelId: 'membaca statistik penggunaan aplikasi',
    ),
    'device.charging': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_charging',
      settingLabel: 'Charging Info',
      settingLabelId: 'Info Pengisian Daya',
      actionLabel: 'read charging info',
      actionLabelId: 'membaca info pengisian daya',
    ),
    'device.dnd': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_dnd',
      settingLabel: 'Do Not Disturb Status',
      settingLabelId: 'Status Jangan Ganggu',
      actionLabel: 'read Do Not Disturb status',
      actionLabelId: 'membaca status Jangan Ganggu',
    ),
    'device.bluetooth': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_bluetooth',
      settingLabel: 'Bluetooth Status',
      settingLabelId: 'Status Bluetooth',
      actionLabel: 'read Bluetooth status',
      actionLabelId: 'membaca status Bluetooth',
    ),
    'device.dnd.set': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_dnd',
      settingLabel: 'Do Not Disturb Status',
      settingLabelId: 'Status Jangan Ganggu',
      actionLabel: 'change Do Not Disturb',
      actionLabelId: 'mengubah Jangan Ganggu',
    ),
    'device.wifi.reconnect': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_network',
      settingLabel: 'Network Info',
      settingLabelId: 'Info Jaringan',
      actionLabel: 'reconnect WiFi',
      actionLabelId: 'menghubungkan ulang WiFi',
    ),
    'device.bluetooth.set': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_bluetooth',
      settingLabel: 'Bluetooth Status',
      settingLabelId: 'Status Bluetooth',
      actionLabel: 'change Bluetooth',
      actionLabelId: 'mengubah Bluetooth',
    ),
    'device.wifi': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_network',
      settingLabel: 'Network Info',
      settingLabelId: 'Info Jaringan',
      actionLabel: 'read WiFi status',
      actionLabelId: 'membaca status WiFi',
    ),
    'device.cellular': ToolPermissionRequirement(
      moduleId: 'device_context',
      settingKey: 'allow_network',
      settingLabel: 'Network Info',
      settingLabelId: 'Info Jaringan',
      actionLabel: 'read cellular status',
      actionLabelId: 'membaca status seluler',
    ),
    'notification.status': ToolPermissionRequirement(
      moduleId: 'notification_intelligence',
      actionLabel: 'check notification access',
      actionLabelId: 'memeriksa akses notifikasi',
    ),
    'notification.read_recent': ToolPermissionRequirement(
      moduleId: 'notification_intelligence',
      settingKey: 'allow_read',
      settingLabel: 'Allow Read Notifications',
      settingLabelId: 'Izinkan Baca Notifikasi',
      actionLabel: 'read notifications',
      actionLabelId: 'membaca notifikasi',
    ),
    'notification.summarize': ToolPermissionRequirement(
      moduleId: 'notification_intelligence',
      settingKey: 'allow_summary',
      settingLabel: 'Allow Notification Summaries',
      settingLabelId: 'Izinkan Ringkasan Notifikasi',
      actionLabel: 'summarize notifications',
      actionLabelId: 'merangkum notifikasi',
    ),
    'notification.classify': ToolPermissionRequirement(
      moduleId: 'notification_intelligence',
      settingKey: 'allow_classify',
      settingLabel: 'Allow Importance Detection',
      settingLabelId: 'Izinkan Deteksi Penting',
      actionLabel: 'classify notifications',
      actionLabelId: 'mengklasifikasi notifikasi',
    ),
    'notification.reply_suggestion': ToolPermissionRequirement(
      moduleId: 'notification_intelligence',
      settingKey: 'allow_reply_suggestion',
      settingLabel: 'Allow Reply Suggestions',
      settingLabelId: 'Izinkan Saran Balasan',
      actionLabel: 'suggest notification replies',
      actionLabelId: 'memberi saran balasan notifikasi',
    ),
    'notification.open_app': ToolPermissionRequirement(
      moduleId: 'notification_intelligence',
      settingKey: 'allow_open_source_app',
      settingLabel: 'Allow Open Source App',
      settingLabelId: 'Izinkan Buka Aplikasi Sumber',
      actionLabel: 'open the notification source app',
      actionLabelId: 'membuka aplikasi sumber notifikasi',
    ),
    'notes.create': ToolPermissionRequirement(
      moduleId: 'notes',
      settingKey: 'allow_create',
      settingLabel: 'Allow Create Notes',
      settingLabelId: 'Izinkan Buat Note',
      actionLabel: 'create notes',
      actionLabelId: 'membuat note',
    ),
    'notes.list_recent': ToolPermissionRequirement(
      moduleId: 'notes',
      settingKey: 'allow_read',
      settingLabel: 'Allow Read Notes',
      settingLabelId: 'Izinkan Baca Note',
      actionLabel: 'list notes',
      actionLabelId: 'melihat daftar note',
    ),
    'notes.read': ToolPermissionRequirement(
      moduleId: 'notes',
      settingKey: 'allow_read',
      settingLabel: 'Allow Read Notes',
      settingLabelId: 'Izinkan Baca Note',
      actionLabel: 'read notes',
      actionLabelId: 'membaca note',
    ),
    'notes.search': ToolPermissionRequirement(
      moduleId: 'notes',
      settingKey: 'allow_search',
      settingLabel: 'Allow Search Notes',
      settingLabelId: 'Izinkan Cari Note',
      actionLabel: 'search notes',
      actionLabelId: 'mencari note',
    ),
    'notes.update': ToolPermissionRequirement(
      moduleId: 'notes',
      settingKey: 'allow_create',
      settingLabel: 'Allow Create Notes',
      settingLabelId: 'Izinkan Buat Note',
      actionLabel: 'update notes',
      actionLabelId: 'mengubah note',
    ),
    'notes.delete': ToolPermissionRequirement(
      moduleId: 'notes',
      settingKey: 'allow_create',
      settingLabel: 'Allow Create Notes',
      settingLabelId: 'Izinkan Buat Note',
      actionLabel: 'delete notes',
      actionLabelId: 'menghapus note',
    ),
    'notes.export': ToolPermissionRequirement(
      moduleId: 'notes',
      settingKey: 'allow_export',
      settingLabel: 'Allow Export Notes',
      settingLabelId: 'Izinkan Export Note',
      actionLabel: 'export notes',
      actionLabelId: 'mengekspor note',
    ),
    'files.create': ToolPermissionRequirement(
      moduleId: 'files',
      settingKey: 'allow_create',
      settingLabel: 'Allow Create Files',
      settingLabelId: 'Izinkan Buat File',
      actionLabel: 'create files',
      actionLabelId: 'membuat file',
    ),
    'files.read': ToolPermissionRequirement(
      moduleId: 'files',
      settingKey: 'allow_read',
      settingLabel: 'Allow Read Files',
      settingLabelId: 'Izinkan Baca File',
      actionLabel: 'read files',
      actionLabelId: 'membaca file',
    ),
    'files.write': ToolPermissionRequirement(
      moduleId: 'files',
      settingKey: 'allow_write',
      settingLabel: 'Allow Write Files',
      settingLabelId: 'Izinkan Tulis File',
      actionLabel: 'write files',
      actionLabelId: 'menulis file',
    ),
    'files.delete': ToolPermissionRequirement(
      moduleId: 'files',
      settingKey: 'allow_delete',
      settingLabel: 'Allow Delete Files',
      settingLabelId: 'Izinkan Hapus File',
      actionLabel: 'delete files',
      actionLabelId: 'menghapus file',
    ),
    'files.list': ToolPermissionRequirement(
      moduleId: 'files',
      settingKey: 'allow_read',
      settingLabel: 'Allow Read Files',
      settingLabelId: 'Izinkan Baca File',
      actionLabel: 'list files',
      actionLabelId: 'melihat daftar file',
    ),
    'files.move': ToolPermissionRequirement(
      moduleId: 'files',
      settingKey: 'allow_organize',
      settingLabel: 'Allow Organize Files',
      settingLabelId: 'Izinkan Organisasi File',
      actionLabel: 'move files',
      actionLabelId: 'memindahkan file',
    ),
    'files.mkdir': ToolPermissionRequirement(
      moduleId: 'files',
      settingKey: 'allow_create',
      settingLabel: 'Allow Create Files',
      settingLabelId: 'Izinkan Buat File',
      actionLabel: 'create folders',
      actionLabelId: 'membuat folder',
    ),
    'calendar.create': ToolPermissionRequirement(
      moduleId: 'calendar',
      settingKey: 'allow_create',
      settingLabel: 'Allow Create Events',
      settingLabelId: 'Izinkan Buat Event',
      actionLabel: 'create calendar events',
      actionLabelId: 'membuat event kalender',
    ),
    'calendar.today': ToolPermissionRequirement(
      moduleId: 'calendar',
      settingKey: 'allow_read',
      settingLabel: 'Allow Read Events',
      settingLabelId: 'Izinkan Baca Event',
      actionLabel: 'read calendar events',
      actionLabelId: 'membaca event kalender',
    ),
    'calendar.list': ToolPermissionRequirement(
      moduleId: 'calendar',
      settingKey: 'allow_read',
      settingLabel: 'Allow Read Events',
      settingLabelId: 'Izinkan Baca Event',
      actionLabel: 'list calendar events',
      actionLabelId: 'melihat daftar event kalender',
    ),
    'calendar.read': ToolPermissionRequirement(
      moduleId: 'calendar',
      settingKey: 'allow_read',
      settingLabel: 'Allow Read Events',
      settingLabelId: 'Izinkan Baca Event',
      actionLabel: 'read calendar events',
      actionLabelId: 'membaca event kalender',
    ),
    'calendar.update': ToolPermissionRequirement(
      moduleId: 'calendar',
      settingKey: 'allow_update',
      settingLabel: 'Allow Update Events',
      settingLabelId: 'Izinkan Update Event',
      actionLabel: 'update calendar events',
      actionLabelId: 'mengubah event kalender',
    ),
    'calendar.delete': ToolPermissionRequirement(
      moduleId: 'calendar',
      settingKey: 'allow_delete',
      settingLabel: 'Allow Delete Events',
      settingLabelId: 'Izinkan Hapus Event',
      actionLabel: 'delete calendar events',
      actionLabelId: 'menghapus event kalender',
    ),
    'workflow.create': ToolPermissionRequirement(
      moduleId: 'workflows',
      settingKey: 'allow_create',
      settingLabel: 'Allow Create Workflows',
      settingLabelId: 'Izinkan Buat Workflow',
      actionLabel: 'create workflows',
      actionLabelId: 'membuat workflow',
    ),
    'workflow.create_from_template': ToolPermissionRequirement(
      moduleId: 'workflows',
      settingKey: 'allow_create',
      settingLabel: 'Allow Create Workflows',
      settingLabelId: 'Izinkan Buat Workflow',
      actionLabel: 'create workflows',
      actionLabelId: 'membuat workflow',
    ),
    'workflow.list_templates': ToolPermissionRequirement(
      moduleId: 'workflows',
      settingKey: 'allow_read',
      settingLabel: 'Allow Read Workflows',
      settingLabelId: 'Izinkan Baca Workflow',
      actionLabel: 'list workflow templates',
      actionLabelId: 'melihat template workflow',
    ),
    'workflow.list': ToolPermissionRequirement(
      moduleId: 'workflows',
      settingKey: 'allow_read',
      settingLabel: 'Allow Read Workflows',
      settingLabelId: 'Izinkan Baca Workflow',
      actionLabel: 'list workflows',
      actionLabelId: 'melihat daftar workflow',
    ),
    'workflow.read': ToolPermissionRequirement(
      moduleId: 'workflows',
      settingKey: 'allow_read',
      settingLabel: 'Allow Read Workflows',
      settingLabelId: 'Izinkan Baca Workflow',
      actionLabel: 'read workflows',
      actionLabelId: 'membaca workflow',
    ),
    'workflow.update': ToolPermissionRequirement(
      moduleId: 'workflows',
      settingKey: 'allow_update',
      settingLabel: 'Allow Update Workflows',
      settingLabelId: 'Izinkan Update Workflow',
      actionLabel: 'update workflows',
      actionLabelId: 'mengubah workflow',
    ),
    'workflow.delete': ToolPermissionRequirement(
      moduleId: 'workflows',
      settingKey: 'allow_delete',
      settingLabel: 'Allow Delete Workflows',
      settingLabelId: 'Izinkan Hapus Workflow',
      actionLabel: 'delete workflows',
      actionLabelId: 'menghapus workflow',
    ),
    'workflow.toggle': ToolPermissionRequirement(
      moduleId: 'workflows',
      settingKey: 'allow_update',
      settingLabel: 'Allow Update Workflows',
      settingLabelId: 'Izinkan Update Workflow',
      actionLabel: 'enable or disable workflows',
      actionLabelId: 'mengaktifkan atau menonaktifkan workflow',
    ),
  };
}
