import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../data/clipboard_service_controller.dart';
import '../data/module_model.dart';
import '../data/module_repository.dart';

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
                const SnackBar(
                  content: Text('Notification permission required.'),
                  duration: Duration(seconds: 2),
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
                const SnackBar(
                  content: Text('Notification permission required.'),
                  duration: Duration(seconds: 2),
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
                const SnackBar(
                  content: Text(
                    'Allow "Display over other apps" to use the bubble.',
                  ),
                  duration: Duration(seconds: 3),
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
            const SnackBar(
              content: Text('URL intents enabled. AI can now open URLs.'),
              duration: Duration(seconds: 2),
            ),
          );
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
            title: const Text('Permission Required'),
            content: const Text(
              'Foreground app detection requires the "Usage Access" '
              'permission.\n\n'
              'Tap "Open Settings" to grant it, then come back.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
        if (goSettings != true) return;
        // Open Usage Access settings screen.
        await const MethodChannel('com.meowagent/app_control')
            .invokeMethod<bool>(
          'openSettings',
          {'action': 'android.settings.USAGE_ACCESS_SETTINGS'},
        );
        // Fall through — save toggle as true so it reflects user intent.
        // If permission wasn't granted, the tool returns available:false gracefully.
      }
    }

    // Device Context — Bluetooth needs BLUETOOTH_CONNECT on Android 12+.
    if (_module!.id == 'device_context' &&
        key == 'allow_bluetooth' &&
        value) {
      try {
        await const MethodChannel('com.meowagent/services')
            .invokeMethod<Map<dynamic, dynamic>>(
          'requestRuntimePermissions',
          {'permissions': ['android.permission.BLUETOOTH_CONNECT']},
        );
      } catch (_) {
        // If denied or error, toggle still saves; tools degrade gracefully.
      }
    }

    // Device Context — DND needs notification policy access.
    if (_module!.id == 'device_context' &&
        key == 'allow_dnd' &&
        value) {
      if (mounted) {
        final goSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Permission Required'),
            content: const Text(
              'Reading Do Not Disturb status requires '
              '"Do Not Disturb access" permission.\n\n'
              'Tap "Open Settings" to grant it, then come back.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
        if (goSettings != true) return;
        await const MethodChannel('com.meowagent/app_control')
            .invokeMethod<bool>(
          'openSettings',
          {'action': 'android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS'},
        );
      }
    }

    // Device Context — Network Info needs Location (WiFi SSID) + Phone (cellular type) on Android 10+.
    if (_module!.id == 'device_context' &&
        key == 'allow_network' &&
        value) {
      try {
        await const MethodChannel('com.meowagent/services')
            .invokeMethod<Map<dynamic, dynamic>>(
          'requestRuntimePermissions',
          {
            'permissions': [
              'android.permission.ACCESS_FINE_LOCATION',
              'android.permission.READ_PHONE_STATE',
            ],
          },
        );
      } catch (_) {
        // If denied or error, toggle still saves; tools degrade gracefully.
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
    final updated = _module!.copyWith(enabled: value);
    await ref.read(moduleRepositoryProvider).update(updated);
    ref.invalidate(installedModulesProvider);
    setState(() => _module = updated);
  }

  Future<void> _uninstall() async {
    if (_module?.id == 'clipboard_ai') {
      final controller = ref.read(clipboardServiceControllerProvider);
      await controller.stopNotificationService();
      await controller.stopBubbleService();
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Uninstall Module'),
        content: Text('Remove ${_module?.name ?? 'this module'}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Uninstall'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(moduleRepositoryProvider).uninstall(widget.moduleId);
      ref.invalidate(installedModulesProvider);
      if (mounted) context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;

    if (_module == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final module = _module!;
    final settingLabels = _settingLabels(module.id);

    return Scaffold(
      appBar: AppBar(
        title: Text(module.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: 'Uninstall',
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
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: extras.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: extras.subtleBorder),
            ),
            child: Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    module.icon,
                    style: const TextStyle(fontSize: 28),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  module.name,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  module.description,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurfaceVariant,
                    height: 1.4,
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
                'Module Enabled',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              subtitle: Text(
                'Turn on to activate this module.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              value: module.enabled,
              onChanged: _toggleEnabled,
            ),
          ),

          const SizedBox(height: 20),

          Text(
            'Triggers',
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
                  onChanged: module.enabled
                      ? (v) => _toggleSetting(entry.key, v)
                      : null,
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Map<String, (String, String)> _settingLabels(String moduleId) {
    switch (moduleId) {
      case 'clipboard_ai':
        return {
          'share_intent': (
            'Share Intent',
            'Receive text via Android Share menu.',
          ),
          'persistent_notification': (
            'Persistent Notification',
            'Show a notification to quickly process clipboard.',
          ),
          'floating_bubble': (
            'Floating Bubble',
            'Draggable bubble overlay on top of all apps.',
          ),
        };
      case 'app_control':
        return {
          'require_confirmation': (
            'Require Confirmation',
            'Ask before opening apps or URLs.',
          ),
          'allow_system_settings': (
            'Allow System Settings',
            'AI can open Android system settings screens.',
          ),
          'allow_url_intents': (
            'Allow URL Intents',
            'AI can open URLs in the browser.',
          ),
          'show_execution_toast': (
            'Show Execution Toast',
            'Show a brief notification when an action runs.',
          ),
        };
      case 'device_context':
        return {
          'allow_battery': (
            'Battery Info',
            'Agent can read battery level and charging status.',
          ),
          'allow_network': (
            'Network Info',
            'Agent can read connection type (WiFi, cellular, etc.). Optional: Location & Phone permissions enable WiFi SSID and 4G/5G detection.',
          ),
          'allow_storage': (
            'Storage Info',
            'Agent can read internal storage usage.',
          ),
          'allow_time_locale': (
            'Time & Locale',
            'Agent can read local time, timezone, and language.',
          ),
          'allow_foreground_app': (
            'Foreground App Detection',
            'Agent can detect which app is currently active. Requires Usage Stats permission.',
          ),
          'allow_charging': (
            'Charging Info',
            'Agent can read charging state and plug type.',
          ),
          'allow_dnd': (
            'Do Not Disturb Status',
            'Agent can read DND mode. Requires notification policy access.',
          ),
          'allow_bluetooth': (
            'Bluetooth Status',
            'Agent can read Bluetooth state and connected devices. Requires Nearby Devices permission.',
          ),
          'show_logs': (
            'Show in Runtime Logs',
            'Include device data in agent debug logs.',
          ),
        };
      default:
        return {};
    }
  }
}
