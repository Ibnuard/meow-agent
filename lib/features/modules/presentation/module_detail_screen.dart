import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../settings/data/app_language_provider.dart';
import '../calendar/calendar_screen.dart';
import '../data/clipboard_service_controller.dart';
import '../data/module_model.dart';
import '../data/module_repository.dart';
import '../web/presentation/api_store_screen.dart';
import '../workflows/workflow_list_screen.dart';
import 'module_visuals.dart';

/// Detail screen for an installed module with toggle settings.
class ModuleDetailScreen extends ConsumerStatefulWidget {
  const ModuleDetailScreen({super.key, required this.moduleId});

  final String moduleId;

  @override
  ConsumerState<ModuleDetailScreen> createState() => _ModuleDetailScreenState();
}

class _ModuleDetailScreenState extends ConsumerState<ModuleDetailScreen>
    with WidgetsBindingObserver {
  ModuleModel? _module;

  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
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
    // Re-check overlay permission when user returns from settings.
    if (state == AppLifecycleState.resumed) {
      _syncBubbleState();
    }
  }

  Future<void> _loadModule() async {
    final modules = await ref.read(moduleRepositoryProvider).getInstalled();
    final found = modules.where((m) => m.id == widget.moduleId).firstOrNull;
    if (mounted && found != null) {
      setState(() => _module = found);
    }
  }

  /// If user enabled floating_bubble but overlay permission was just granted,
  /// start the service automatically.
  Future<void> _syncBubbleState() async {
    if (_module == null || _module!.id != 'clipboard_ai') return;
    final wantsBubble = _module!.settings['floating_bubble'] ?? false;
    if (!wantsBubble) return;

    final controller = ref.read(clipboardServiceControllerProvider);
    final canDraw = await controller.canDrawOverlays();
    final running = await controller.isBubbleServiceRunning();
    if (canDraw && !running) {
      await controller.startBubbleService();
    }
  }

  Future<void> _toggleSetting(String key, bool value) async {
    if (_module == null) return;

    if (_module!.id == 'clipboard_ai') {
      final controller = ref.read(clipboardServiceControllerProvider);

      if (key == 'persistent_notification') {
        if (value) {
          final granted = await controller.requestNotificationPermission();
          if (!granted) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(s.notificationPermissionRequired),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
            return;
          }
          await controller.startNotificationService();
        } else {
          await controller.stopNotificationService();
        }
      }

      if (key == 'floating_bubble') {
        if (value) {
          // Need POST_NOTIFICATIONS for the foreground service notification.
          final notifGranted = await controller.requestNotificationPermission();
          if (!notifGranted) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(s.notificationPermissionRequired),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
            return;
          }
          // Need SYSTEM_ALERT_WINDOW to draw the bubble overlay.
          final canDraw = await controller.canDrawOverlays();
          if (!canDraw) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(s.overlayPermissionRequired),
                  duration: const Duration(seconds: 3),
                ),
              );
            }
            await controller.requestOverlayPermission();
            // Don't toggle yet — will sync on resume.
            return;
          }
          await controller.startBubbleService();
        } else {
          await controller.stopBubbleService();
        }
      }
    }

    // App Control — settings are purely preference toggles, no native service.
    // The runtime engine reads these before executing app control tools.
    if (_module!.id == 'app_control') {
      // No native service to start/stop — just persist the toggle.
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

      // Background launch needs SYSTEM_ALERT_WINDOW. Without it Android 10+
      // will silently drop activity launches when Meow Agent is backgrounded.
      if (value && key == 'allow_background_launch') {
        final controller = ref.read(clipboardServiceControllerProvider);
        final canDraw = await controller.canDrawOverlays();
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
            await controller.requestOverlayPermission();
            // Don't toggle yet — wait for user to grant and return.
            // Re-check on the next interaction; user can tap again.
            return;
          }
        }
      }
    }

    // Device Context — foreground app needs PACKAGE_USAGE_STATS permission.
    if (_module!.id == 'device_context' &&
        key == 'allow_foreground_app' &&
        value) {
      if (mounted) {
        final goSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(s.permissionRequired),
            content: Text(
              s.isId
                  ? 'Deteksi aplikasi aktif membutuhkan izin "Akses Penggunaan".\n\n'
                        'Tap "${s.openSettings}" untuk memberikan izin, lalu kembali.'
                  : 'Foreground app detection requires the "Usage Access" '
                        'permission.\n\n'
                        'Tap "Open Settings" to grant it, then come back.',
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
        // Open Usage Access settings screen.
        await const MethodChannel(
          'com.meowagent/app_control',
        ).invokeMethod<bool>('openSettings', {
          'action': 'android.settings.USAGE_ACCESS_SETTINGS',
        });
        // Fall through — save toggle as true so it reflects user intent.
        // If permission wasn't granted, the tool returns available:false gracefully.
      }
    }

    // Device Context — Bluetooth needs BLUETOOTH_CONNECT on Android 12+.
    if (_module!.id == 'device_context' && key == 'allow_bluetooth' && value) {
      try {
        await const MethodChannel(
          'com.meowagent/services',
        ).invokeMethod<Map<dynamic, dynamic>>('requestRuntimePermissions', {
          'permissions': ['android.permission.BLUETOOTH_CONNECT'],
        });
      } catch (_) {
        // If denied or error, toggle still saves; tools degrade gracefully.
      }
    }

    // Device Context — DND needs notification policy access.
    if (_module!.id == 'device_context' && key == 'allow_dnd' && value) {
      if (mounted) {
        final goSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(s.permissionRequired),
            content: Text(
              s.isId
                  ? 'Membaca status Jangan Ganggu membutuhkan izin "Akses Do Not Disturb".\n\n'
                        'Tap "${s.openSettings}" untuk memberikan izin, lalu kembali.'
                  : 'Reading Do Not Disturb status requires '
                        '"Do Not Disturb access" permission.\n\n'
                        'Tap "Open Settings" to grant it, then come back.',
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
        await const MethodChannel(
          'com.meowagent/app_control',
        ).invokeMethod<bool>('openSettings', {
          'action': 'android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS',
        });
      }
    }

    // Device Context — Network Info needs Location (WiFi SSID) + Phone (cellular type) on Android 10+.
    if (_module!.id == 'device_context' && key == 'allow_network' && value) {
      try {
        await const MethodChannel(
          'com.meowagent/services',
        ).invokeMethod<Map<dynamic, dynamic>>('requestRuntimePermissions', {
          'permissions': [
            'android.permission.ACCESS_FINE_LOCATION',
            'android.permission.READ_PHONE_STATE',
          ],
        });
      } catch (_) {
        // If denied or error, toggle still saves; tools degrade gracefully.
      }
    }

    // Notification Intelligence — needs Notification access (Special Access).
    // Cannot be granted via runtime dialog — must redirect to settings.
    if (_module!.id == 'notification_intelligence' &&
        key == 'allow_read' &&
        value) {
      if (mounted) {
        final goSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(s.permissionRequired),
            content: Text(
              s.isId
                  ? 'Membaca notifikasi membutuhkan izin "Akses Notifikasi".\n\n'
                        'Tap "${s.openSettings}", cari "Meow Agent" di daftar, dan aktifkan akses.\n\n'
                        'Kamu bisa lewati ini — toggle akan tersimpan, tapi agen tidak bisa membaca notifikasi sampai akses diberikan.'
                  : 'Reading notifications requires "Notification access" permission.\n\n'
                        'Tap "Open Settings", find "Meow Agent" in the list, and enable access.\n\n'
                        'You can skip this — the toggle will save, but the agent will not be able to read notifications until access is granted.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(s.skip),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(s.openSettings),
              ),
            ],
          ),
        );
        if (goSettings == true) {
          await const MethodChannel(
            'com.meowagent/notifications',
          ).invokeMethod<bool>('openNotificationAccessSettings');
        }
      }
    }

    final updated = _module!.copyWith(
      settings: {..._module!.settings, key: value},
    );
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
    try {
      const channel = MethodChannel('com.meowagent/alarm_permission');
      final result = await channel.invokeMethod<bool>('canScheduleExactAlarms');
      return result ?? false;
    } catch (_) {
      // If check fails (older Android), assume granted.
      return true;
    }
  }

  /// Open system alarm permission settings.
  Future<void> _openAlarmSettings() async {
    try {
      const channel = MethodChannel('com.meowagent/alarm_permission');
      await channel.invokeMethod('openAlarmSettings');
    } catch (_) {
      // Fallback: do nothing.
    }
  }

  Future<void> _uninstall() async {
    if (_module?.id == 'clipboard_ai') {
      final controller = ref.read(clipboardServiceControllerProvider);
      await controller.stopNotificationService();
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
              decoration: BoxDecoration(
                color: extras.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: extras.subtleBorder),
              ),
              child: Column(
                children: module.settings.entries.map((entry) {
                  final label = settingLabels[entry.key];
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
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                          )
                        : null,
                    value: entry.value,
                    activeTrackColor: cs.primary.withValues(alpha: 0.82),
                    activeThumbColor: Colors.white,
                    inactiveTrackColor: cs.onSurfaceVariant.withValues(
                      alpha: 0.22,
                    ),
                    inactiveThumbColor: cs.onSurfaceVariant.withValues(
                      alpha: 0.72,
                    ),
                    onChanged: (v) => _toggleSetting(entry.key, v),
                  );
                }).toList(),
              ),
            ),
          ],
        ],
      ),
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
