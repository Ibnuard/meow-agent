import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../../services/permission/permission_manager.dart';
import '../../settings/data/app_language_provider.dart';
import '../calendar/calendar_screen.dart';
import '../data/app_control_service.dart';
import '../data/clipboard_service_controller.dart';
import '../data/shizuku_status.dart';
import '../data/module_model.dart';
import '../data/module_repository.dart';
import '../web/presentation/api_store_screen.dart';
import '../workflows/workflow_list_screen.dart';
import 'module_visuals.dart';
import 'mixins/super_power_handler.dart';
import 'mixins/device_context_handler.dart';
import 'mixins/communication_handler.dart';
import 'mixins/notification_intelligence_handler.dart';
import 'mixins/clipboard_ai_handler.dart';

/// Detail screen for an installed module with toggle settings.
class ModuleDetailScreen extends ConsumerStatefulWidget {
  const ModuleDetailScreen({super.key, required this.moduleId});

  final String moduleId;

  @override
  ConsumerState<ModuleDetailScreen> createState() => _ModuleDetailScreenState();
}

class _ModuleDetailScreenState extends ConsumerState<ModuleDetailScreen>
    with
        WidgetsBindingObserver,
        SuperPowerHandlerMixin,
        DeviceContextHandlerMixin,
        CommunicationHandlerMixin,
        NotificationIntelligenceHandlerMixin,
        ClipboardAiHandlerMixin {
  ModuleModel? _module;
  ShizukuStatus? _shizukuStatus;
  bool _checkingShizuku = false;
  bool _requestingShizukuPermission = false;
  bool _pendingAppAgenticEnable = false;
  Future<Widget?>? _pinStatusFuture;

  @override
  ModuleModel? get module => _module;
  
  @override
  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }
  
  @override
  PermissionManager get permissionManager => ref.read(permissionManagerProvider);

  @override
  ShizukuStatus? get shizukuStatus => _shizukuStatus;
  @override
  set shizukuStatus(ShizukuStatus? value) {
    if (mounted) {
      setState(() => _shizukuStatus = value);
    }
  }

  @override
  bool get checkingShizuku => _checkingShizuku;
  @override
  set checkingShizuku(bool value) {
    if (mounted) {
      setState(() => _checkingShizuku = value);
    }
  }

  @override
  bool get requestingShizukuPermission => _requestingShizukuPermission;
  @override
  set requestingShizukuPermission(bool value) {
    if (mounted) {
      setState(() => _requestingShizukuPermission = value);
    }
  }

  @override
  bool get pendingAppAgenticEnable => _pendingAppAgenticEnable;
  @override
  set pendingAppAgenticEnable(bool value) {
    if (mounted) {
      setState(() => _pendingAppAgenticEnable = value);
    }
  }

  @override
  void onModuleUpdated(ModuleModel updated) {
    if (mounted) {
      setState(() => _module = updated);
      _refreshPinStatus();
    }
  }

  void _refreshPinStatus() {
    if (_module?.id == 'super_power') {
      _pinStatusFuture = buildDevicePinStatusPanel(
        cs: Theme.of(context).colorScheme,
      );
    }
  }

  @override
  void refreshDevicePinPanel() {
    if (mounted) {
      setState(() => _refreshPinStatus());
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadModule();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check permissions when user returns from settings.
    if (state == AppLifecycleState.resumed) {
      _syncCommunicationState();
      _syncSuperPowerBubble();
      syncSuperPowerPermissions();
      refreshShizukuStatus();
      _refreshPinStatus();
    }
  }

  Future<void> _loadModule() async {
    final modules = await ref.read(moduleRepositoryProvider).getInstalled();
    final found = modules.where((m) => m.id == widget.moduleId).firstOrNull;
    if (mounted && found != null) {
      setState(() => _module = found);
      // Sync permission state immediately on load.
      _syncCommunicationState();
      syncSuperPowerPermissions();
      refreshShizukuStatus();
      _refreshPinStatus();
    }
  }

  /// Sync communication module state when returning from settings.
  Future<void> _syncCommunicationState() async {
    if (_module == null || _module!.id != 'communication') return;
    // No WA/Telegram state to sync anymore — call/sms/contacts
    // permissions are handled inline on toggle.
  }

  Future<void> _toggleSetting(String key, bool value) async {
    if (_module == null) return;

    await handleClipboardAiToggle(key, value);
    await handleDeviceContextToggle(key, value);
    await handleCommunicationToggle(key, value);
    await handleNotificationIntelligenceToggle(key, value);
    await handleSuperPowerToggle(key, value);

    // App Control — settings are purely preference toggles, no native service.
    if (_module!.id == 'app_control') {
      if (value && key == 'allow_url_intents') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(s.urlIntentsEnabled),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }

      if (value && key == 'allow_background_launch') {
        final canDraw = await permissionManager.isGranted(
          PermissionType.systemAlertWindow,
        );
        if (!canDraw) {
          if (mounted) {
            final goSettings = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(s.permissionRequired),
                content: Text(
                  s.isId
                      ? 'Untuk membuka aplikasi saat Meow Agent di latar belakang, '
                            'Android membutuhkan izin "Tampilkan di atas aplikasi lain".\n\n'
                            'Tap "${s.openSettings}" untuk mengaktifkan, lalu kembali.'
                      : 'To open apps while Meow Agent is in the background, '
                            'Android requires the "Display over other apps" permission.\n\n'
                            'Tap "Open Settings" to enable it, then come back.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(s.cancel),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(s.openSettings),
                  ),
                ],
              ),
            );
            if (goSettings != true) return;
            await permissionManager.request(PermissionType.systemAlertWindow);
            return;
          }
        }
      }
    }

    var nextSettings = {..._module!.settings, key: value};
      if (_module!.id == 'super_power') {
        if (key == 'app_agentic' && !value) {
          nextSettings = {
            ...nextSettings,
            'run_locked_device': false,
          };
        }
      }

    final updated = _module!.copyWith(settings: nextSettings);
    await ref.read(moduleRepositoryProvider).update(updated);
    ref.invalidate(installedModulesProvider);
    setState(() => _module = updated);
  }

  Future<void> _toggleEnabled(bool value) async {
    if (_module == null) return;

    // Workflow module requires SCHEDULE_EXACT_ALARM permission on Android 14+.
    if (value && _module!.id == 'workflows') {
      final granted = await _checkAlarmPermission();
      if (!granted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(s.alarmsPermissionRequired),
            action: SnackBarAction(
              label: s.openLabel,
              onPressed: _openAlarmSettings,
            ),
          ),
        );
        return;
      }
    }

    final updated = _module!.copyWith(enabled: value);
    await ref.read(moduleRepositoryProvider).update(updated);
    ref.invalidate(installedModulesProvider);
    setState(() => _module = updated);
  }

  /// Check if SCHEDULE_EXACT_ALARM permission is granted.
  Future<bool> _checkAlarmPermission() async {
    final result = await permissionManager.check(
      PermissionType.scheduleExactAlarm,
    );
    return result == PermissionResult.granted;
  }

  /// Open system alarm permission settings.
  Future<void> _openAlarmSettings() async {
    await permissionManager.openAlarmSettings();
  }

  /// Sync bubble state on resume (for Super Power module).
  Future<void> _syncSuperPowerBubble() async {
    if (_module == null || _module!.id != 'super_power') return;
    final wantsBubble = _module!.settings['overlay_bubble'] ?? false;
    if (!wantsBubble) return;

    final canDraw = await permissionManager.isGranted(
      PermissionType.systemAlertWindow,
    );
    final running = await ref
        .read(clipboardServiceControllerProvider)
        .isBubbleServiceRunning();
    if (canDraw && !running) {
      await ref.read(clipboardServiceControllerProvider).startBubbleService();
    }
  }

  Future<void> _uninstall() async {
    if (_module?.id == 'clipboard_ai') {
      final controller = ref.read(clipboardServiceControllerProvider);
      await controller.stopNotificationService();
      await controller.stopBubbleService();
    }
    if (_module?.id == 'super_power') {
      final controller = ref.read(clipboardServiceControllerProvider);
      await controller.stopBubbleService();
    }

    if (!mounted) return;
    final confirmed = await showMeowConfirmDialog(
      context,
      isId: s.isId,
      title: s.uninstallModule,
      message: s.moduleUninstallDialog(_module?.name ?? 'modul ini'),
      confirmLabel: s.uninstall,
      cancelLabel: s.cancel,
    );
    if (confirmed && mounted) {
      await ref.read(moduleRepositoryProvider).uninstall(widget.moduleId);
      ref.invalidate(installedModulesProvider);
      if (mounted) context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_module == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final module = _module!;
    final languagePref = ref.watch(appLanguageProvider);
    final langCode = resolveLanguageCode(languagePref);
    final isId = langCode == 'id';
    final settingLabels = _settingLabels(module.id, isId: isId);

    return Scaffold(
      backgroundColor: isDark ? cs.surface : const Color(0xFFFBFCFE),
      appBar: AppBar(
        title: Text(module.name),
        actions: [
          IconButton(
            icon: Icon(Icons.delete_outline_rounded, color: cs.error),
            tooltip: s.uninstallTooltip,
            onPressed: _uninstall,
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(context).padding.bottom + 24,
        ),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: isDark ? extras.card : const Color(0xFFF4F7FB),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark ? extras.subtleBorder : const Color(0xFFEAF0F8),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ModuleIconBadge(
                  moduleId: module.id,
                  size: 58,
                  iconSize: 27,
                  radius: 20,
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        module.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: cs.onSurface,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        _moduleDescription(module, isId: isId),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: extras.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: extras.subtleBorder),
            ),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                s.moduleEnabled,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              subtitle: Text(
                s.moduleEnabledDesc,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              value: module.enabled,
              activeTrackColor: cs.primary.withValues(alpha: 0.82),
              activeThumbColor: Colors.white,
              inactiveTrackColor: cs.onSurfaceVariant.withValues(alpha: 0.22),
              inactiveThumbColor: cs.onSurfaceVariant.withValues(alpha: 0.72),
              onChanged: _toggleEnabled,
            ),
          ),

          const SizedBox(height: 20),

          // Notes module: show "Open Notes" button when enabled.
          if (module.id == 'notes' && module.enabled) ...[
            GestureDetector(
              onTap: () => context.push('/notes'),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.note_outlined, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      s.openNotes,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Calendar module: show "Open Calendar" button when enabled.
          if (module.id == 'calendar' && module.enabled) ...[
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CalendarScreen()),
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.calendar_month_rounded,
                      size: 18,
                      color: cs.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      s.openCalendar,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Workflows module: show "Open Workflows" button when enabled.
          if (module.id == 'workflows' && module.enabled) ...[
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const WorkflowListScreen()),
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.schedule_rounded, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      s.openWorkflows,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Web/API module: show "Open API Store" button when enabled.
          if (module.id == 'web' && module.enabled) ...[
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ApiStoreScreen()),
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.cloud_rounded, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      s.openApiStore,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          if (module.id == 'super_power' &&
              module.enabled &&
              module.settings['app_agentic'] == true) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: extras.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: extras.subtleBorder),
              ),
              child: _buildShizukuSupportPanel(cs: cs, s: s),
            ),
            const SizedBox(height: 20),
          ],

          if (module.enabled) ...[
            Text(
              s.featurePermission,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: extras.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: extras.subtleBorder),
              ),
              child: Column(
                children: [
                  for (final entry in module.settings.entries)
                    if (_settingVisible(module, entry)) ...[
                      _buildSettingSwitch(
                        entry: entry,
                        label: settingLabels[entry.key],
                        cs: cs,
                      ),
                      if (module.id == 'super_power' &&
                          entry.key == 'run_locked_device')
                        FutureBuilder<Widget?>(
                          future: _pinStatusFuture,
                          builder: (ctx, snap) =>
                              snap.data ?? const SizedBox.shrink(),
                        ),
                    ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  bool _settingVisible(ModuleModel module, MapEntry<String, bool> entry) {
    if (module.id != 'super_power') return true;
    // Legacy key — no longer shown as a separate toggle.
    if (entry.key == 'app_agentic_support_shizuku') return false;
    if (entry.key == 'run_locked_device') {
      return module.settings['app_agentic'] == true;
    }
    return true;
  }

  Widget _buildSettingSwitch({
    required MapEntry<String, bool> entry,
    required (String, String)? label,
    required ColorScheme cs,
  }) {
    return SwitchListTile(
      title: Text(
        label?.$1 ?? entry.key,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: cs.onSurface,
        ),
      ),
      subtitle: label != null
          ? Text(
              label.$2,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            )
          : null,
      value: entry.value,
      activeTrackColor: cs.primary.withValues(alpha: 0.82),
      activeThumbColor: Colors.white,
      inactiveTrackColor: cs.onSurfaceVariant.withValues(alpha: 0.22),
      inactiveThumbColor: cs.onSurfaceVariant.withValues(alpha: 0.72),
      onChanged: (v) => _toggleSetting(entry.key, v),
    );
  }

  Widget _buildShizukuSupportPanel({
    required ColorScheme cs,
    required AppStrings s,
  }) {
    return Column(
      children: [
        buildShizukuStatusPanel(cs: cs),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await refreshShizukuStatus();
                },
                icon: const Icon(Icons.check_circle_outline, size: 16),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(s.checkStatus, maxLines: 1, softWrap: false),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: cs.primary,
                  side: BorderSide(color: cs.primary.withValues(alpha: 0.4)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await requestShizukuPermission();
                },
                icon: const Icon(Icons.verified_user_outlined, size: 16),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    s.requestPermission,
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: cs.primary,
                  side: BorderSide(color: cs.primary.withValues(alpha: 0.4)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () async {
              await AppControlService().openUrl(
                'https://shizuku.rikka.app/guide/setup/',
              );
            },
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: Text(s.setupGuide),
            style: OutlinedButton.styleFrom(
              foregroundColor: cs.onSurfaceVariant,
              side: BorderSide(
                color: cs.onSurfaceVariant.withValues(alpha: 0.3),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _moduleDescription(ModuleModel module, {required bool isId}) {
    final s = AppStrings(isId ? 'id' : 'en');
    switch (module.id) {
      case 'clipboard_ai':
        return s.moduleDescClipboard;
      case 'app_control':
        return s.moduleDescAppControl;
      case 'device_context':
        return s.moduleDescDeviceContext;
      case 'notification_intelligence':
        return s.moduleDescNotification;
      case 'notes':
        return s.moduleDescNotes;
      case 'files':
        return s.moduleDescFiles;
      case 'calendar':
        return s.moduleDescCalendar;
      case 'workflows':
        return s.moduleDescWorkflows;
      case 'web':
        return s.moduleDescWeb;
      case 'super_power':
        return s.moduleDescSuperPower;
      default:
        return module.description;
    }
  }

  Map<String, (String, String)> _settingLabels(
    String moduleId, {
    required bool isId,
  }) {
    final s = AppStrings(isId ? 'id' : 'en');
    final labels = <String, (String, String)>{};
    for (final entry in _module!.settings.entries) {
      labels[entry.key] = s.moduleSetting(moduleId, entry.key);
    }
    return labels;
  }
}
