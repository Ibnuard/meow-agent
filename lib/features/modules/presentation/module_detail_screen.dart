import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../../services/permission/permission_manager.dart';
import '../../settings/data/app_language_provider.dart';
import '../calendar/calendar_screen.dart';
import '../data/app_control_service.dart';
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
  _ShizukuStatus? _shizukuStatus;
  bool _checkingShizuku = false;
  bool _requestingShizukuPermission = false;
  bool _pendingAppAgenticEnable = false;

  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }

  PermissionManager get _permissionManager =>
      ref.read(permissionManagerProvider);

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
      _syncSuperPowerPermissions();
      _refreshShizukuStatus();
    }
  }

  Future<void> _loadModule() async {
    final modules = await ref.read(moduleRepositoryProvider).getInstalled();
    final found = modules.where((m) => m.id == widget.moduleId).firstOrNull;
    if (mounted && found != null) {
      setState(() => _module = found);
      // Sync permission state immediately on load.
      _syncCommunicationState();
      _syncSuperPowerPermissions();
      _refreshShizukuStatus();
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

    if (_module!.id == 'clipboard_ai') {
      if (key == 'persistent_notification') {
        if (value) {
          final granted =
              await _permissionManager.request(PermissionType.notification) ==
              PermissionResult.granted;
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
          await ref
              .read(clipboardServiceControllerProvider)
              .startNotificationService();
        } else {
          await ref
              .read(clipboardServiceControllerProvider)
              .stopNotificationService();
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
        final canDraw = await _permissionManager.isGranted(
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
            await _permissionManager.request(PermissionType.systemAlertWindow);
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
        await _permissionManager.openUsageAccessSettings();
        // Fall through — save toggle as true so it reflects user intent.
        // If permission wasn't granted, the tool returns available:false gracefully.
      }
    }

    // Device Context — Bluetooth needs BLUETOOTH_CONNECT on Android 12+.
    if (_module!.id == 'device_context' && key == 'allow_bluetooth' && value) {
      final result = await _permissionManager.request(
        PermissionType.bluetoothConnect,
      );
      if (result != PermissionResult.granted) {
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
        await _permissionManager.openNotificationPolicySettings();
      }
    }

    // Device Context — Network Info needs Location (WiFi SSID) + Phone (cellular type) on Android 10+.
    if (_module!.id == 'device_context' && key == 'allow_network' && value) {
      await _permissionManager.request(PermissionType.location);
      await _permissionManager.request(PermissionType.phoneState);
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
          await _permissionManager.openNotificationListenerSettings();
        }
      }
    }

    // Communication module — permission gating per feature.
    if (_module!.id == 'communication') {
      // Phone call needs CALL_PHONE permission.
      if (value && key == 'call_enabled') {
        final result = await _permissionManager.request(
          PermissionType.callPhone,
        );
        if (result != PermissionResult.granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  s.isId
                      ? 'Izin telepon diperlukan untuk fitur ini'
                      : 'Phone call permission required for this feature',
                ),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return;
        }
      }

      // SMS needs SEND_SMS permission.
      if (value && key == 'sms_enabled') {
        final result = await _permissionManager.request(PermissionType.sendSms);
        if (result != PermissionResult.granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  s.isId
                      ? 'Izin SMS diperlukan untuk fitur ini'
                      : 'SMS permission required for this feature',
                ),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return;
        }
      }

      // Contacts needs READ_CONTACTS permission.
      if (value && key == 'contact_access') {
        final result = await _permissionManager.request(
          PermissionType.contacts,
        );
        if (result != PermissionResult.granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  s.isId
                      ? 'Izin kontak diperlukan untuk fitur ini'
                      : 'Contacts permission required for this feature',
                ),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return;
        }
      }
    }

    // Super Power module — overlay bubble + Shizuku app agentic.
    if (_module!.id == 'super_power') {
      if (key == 'overlay_bubble') {
        if (value) {
          // Need POST_NOTIFICATIONS for the foreground service notification.
          final notifGranted =
              await _permissionManager.request(PermissionType.notification) ==
              PermissionResult.granted;
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
          final canDraw = await _permissionManager.isGranted(
            PermissionType.systemAlertWindow,
          );
          if (!canDraw) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(s.overlayPermissionRequired),
                  duration: const Duration(seconds: 3),
                ),
              );
            }
            await _permissionManager.request(PermissionType.systemAlertWindow);
            // Don't toggle yet — will sync on resume.
            return;
          }
          await ref
              .read(clipboardServiceControllerProvider)
              .startBubbleService();
        } else {
          await ref
              .read(clipboardServiceControllerProvider)
              .stopBubbleService();
        }
      }

      if (key == 'app_agentic' && value) {
        final accessibilityEnabled = await _isAccessibilityEnabled();
        if (!accessibilityEnabled) {
          _pendingAppAgenticEnable = true;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(s.accessibilityRequired),
                duration: const Duration(seconds: 3),
              ),
            );
          }
          await _permissionManager.openAccessibilitySettings();
          return;
        }
      }

      if ((key == 'app_agentic_support_shizuku' ||
              key == 'run_locked_device') &&
          value) {
        if (_module!.settings['app_agentic'] != true) return;
        if (key == 'run_locked_device' &&
            _module!.settings['app_agentic_support_shizuku'] != true) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(s.shizukuSupportRequired),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return;
        }
        final shizukuReady = await _checkShizukuStatus();
        if (!shizukuReady) {
          if (_shizukuStatus?.available == true) {
            await _requestShizukuPermission();
          }
          if (_shizukuStatus?.isReady != true) return;
        }
      }
    }

    var nextSettings = {..._module!.settings, key: value};
    if (_module!.id == 'super_power') {
      if (key == 'app_agentic' && !value) {
        nextSettings = {
          ...nextSettings,
          'app_agentic_support_shizuku': false,
          'run_locked_device': false,
        };
      }
      if (key == 'app_agentic_support_shizuku' && !value) {
        nextSettings = {...nextSettings, 'run_locked_device': false};
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
    final result = await _permissionManager.check(
      PermissionType.scheduleExactAlarm,
    );
    return result == PermissionResult.granted;
  }

  /// Open system alarm permission settings.
  Future<void> _openAlarmSettings() async {
    await _permissionManager.openAlarmSettings();
  }

  Future<bool> _isAccessibilityEnabled() async {
    try {
      const channel = MethodChannel('com.meowagent/shizuku');
      return await channel.invokeMethod<bool>('isAccessibilityEnabled') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _syncSuperPowerPermissions() async {
    if (_module == null || _module!.id != 'super_power') return;
    final settings = Map<String, bool>.from(_module!.settings);
    var changed = false;

    final accessibilityEnabled = await _isAccessibilityEnabled();
    if (_pendingAppAgenticEnable && accessibilityEnabled) {
      settings['app_agentic'] = true;
      changed = true;
    }
    _pendingAppAgenticEnable = false;

    if (settings['app_agentic'] == true && !accessibilityEnabled) {
      settings['app_agentic'] = false;
      settings['app_agentic_support_shizuku'] = false;
      settings['run_locked_device'] = false;
      changed = true;
    }

    if (settings['app_agentic'] != true) {
      if (settings['app_agentic_support_shizuku'] == true ||
          settings['run_locked_device'] == true) {
        settings['app_agentic_support_shizuku'] = false;
        settings['run_locked_device'] = false;
        changed = true;
      }
    } else if (settings['app_agentic_support_shizuku'] != true &&
        settings['run_locked_device'] == true) {
      settings['run_locked_device'] = false;
      changed = true;
    }

    if (!changed || !mounted) return;
    final updated = _module!.copyWith(settings: settings);
    await ref.read(moduleRepositoryProvider).update(updated);
    ref.invalidate(installedModulesProvider);
    if (mounted) {
      setState(() => _module = updated);
    }
  }

  /// Check Shizuku status via the same MethodChannel API used by ShizukuTestScreen.
  Future<bool> _checkShizukuStatus() async {
    final status = await _refreshShizukuStatus();
    return status.isReady;
  }

  Future<_ShizukuStatus> _refreshShizukuStatus() async {
    if (_module == null || _module!.id != 'super_power') {
      return const _ShizukuStatus.unknown();
    }
    if (mounted) {
      setState(() => _checkingShizuku = true);
    }
    try {
      const channel = MethodChannel('com.meowagent/shizuku');
      final result = await channel.invokeMethod('getStatus');
      final data = Map<String, dynamic>.from(result as Map);
      final status = _ShizukuStatus(
        available: data['shizuku_available'] == true,
        permissionGranted: data['permission_granted'] == true,
      );
      if (mounted) {
        setState(() {
          _shizukuStatus = status;
          _checkingShizuku = false;
        });
      }
      return status;
    } catch (e) {
      final status = _ShizukuStatus(error: e.toString());
      if (mounted) {
        setState(() {
          _shizukuStatus = status;
          _checkingShizuku = false;
        });
      }
      return status;
    }
  }

  Future<void> _requestShizukuPermission() async {
    if (_requestingShizukuPermission) return;
    if (mounted) {
      setState(() => _requestingShizukuPermission = true);
    }
    try {
      const channel = MethodChannel('com.meowagent/shizuku');
      await channel.invokeMethod('requestPermission');
      if (mounted) {
        setState(() {
          _requestingShizukuPermission = false;
          _shizukuStatus = _ShizukuStatus(
            available: _shizukuStatus?.available,
            permissionGranted: _shizukuStatus?.permissionGranted,
            requestPending: true,
          );
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _refreshShizukuStatus();
    } catch (e) {
      if (mounted) {
        setState(() {
          _requestingShizukuPermission = false;
          _shizukuStatus = _ShizukuStatus(error: e.toString());
        });
      }
    }
  }

  Widget _buildShizukuStatusPanel({
    required ColorScheme cs,
    required AppStrings s,
  }) {
    final status = _shizukuStatus;
    final isChecking = _checkingShizuku && status == null;
    final icon = isChecking
        ? Icons.sync_rounded
        : status?.icon ?? Icons.help_outline_rounded;
    final color = isChecking ? cs.primary : status?.color(cs) ?? cs.outline;
    final message = isChecking
        ? s.shizukuStatusChecking
        : status?.message(s) ?? s.shizukuStatusUnknown;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isChecking)
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, color: cs.onSurface, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  /// Sync bubble state on resume (for Super Power module).
  Future<void> _syncSuperPowerBubble() async {
    if (_module == null || _module!.id != 'super_power') return;
    final wantsBubble = _module!.settings['overlay_bubble'] ?? false;
    if (!wantsBubble) return;

    final canDraw = await _permissionManager.isGranted(
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
                children: _visibleSettingEntries(module).expand((entry) {
                  return [
                    _buildSettingSwitch(
                      entry: entry,
                      label: settingLabels[entry.key],
                      cs: cs,
                    ),
                  ];
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Iterable<MapEntry<String, bool>> _visibleSettingEntries(ModuleModel module) {
    if (module.id != 'super_power') return module.settings.entries;
    final appAgenticOn = module.settings['app_agentic'] == true;
    final shizukuSupportOn =
        module.settings['app_agentic_support_shizuku'] == true;
    return module.settings.entries.where((entry) {
      if (entry.key == 'app_agentic_support_shizuku') return appAgenticOn;
      if (entry.key == 'run_locked_device') {
        return appAgenticOn && shizukuSupportOn;
      }
      return true;
    });
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
        _buildShizukuStatusPanel(cs: cs, s: s),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await _refreshShizukuStatus();
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
                  await _requestShizukuPermission();
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

class _ShizukuStatus {
  const _ShizukuStatus({
    this.available,
    this.permissionGranted,
    this.requestPending = false,
    this.error,
  });

  const _ShizukuStatus.unknown()
    : available = null,
      permissionGranted = null,
      requestPending = false,
      error = null;

  final bool? available;
  final bool? permissionGranted;
  final bool requestPending;
  final String? error;

  bool get isReady => available == true && permissionGranted == true;

  IconData get icon {
    if (error != null) return Icons.error_outline_rounded;
    if (requestPending) return Icons.hourglass_top_rounded;
    if (isReady) return Icons.check_circle_rounded;
    if (available == true) return Icons.verified_user_outlined;
    if (available == false) return Icons.power_settings_new_rounded;
    return Icons.help_outline_rounded;
  }

  Color color(ColorScheme cs) {
    if (error != null) return cs.error;
    if (isReady) return const Color(0xFF22C55E);
    if (requestPending || available == true) return const Color(0xFFF59E0B);
    if (available == false) return cs.onSurfaceVariant;
    return cs.outline;
  }

  String message(AppStrings s) {
    if (error != null) return s.shizukuStatusError(error!);
    if (requestPending) return s.shizukuStatusRequestPending;
    if (isReady) return s.shizukuStatusReady;
    if (available == true) return s.shizukuStatusPermissionNeeded;
    if (available == false) return s.shizukuStatusUnavailable;
    return s.shizukuStatusUnknown;
  }
}
