import 'package:flutter/material.dart';
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
    // Re-check accessibility status when user returns from settings.
    if (state == AppLifecycleState.resumed) {
      _syncAccessibilityState();
    }
  }

  Future<void> _loadModule() async {
    final modules = await ref.read(moduleRepositoryProvider).getInstalled();
    final found = modules.where((m) => m.id == widget.moduleId).firstOrNull;
    if (mounted && found != null) {
      setState(() => _module = found);
    }
  }

  Future<void> _syncAccessibilityState() async {
    if (_module == null || _module!.id != 'clipboard_ai') return;
    final controller = ref.read(clipboardServiceControllerProvider);
    final isEnabled = await controller.isAccessibilityEnabled();
    final current = _module!.settings['accessibility_service'] ?? false;
    if (isEnabled != current) {
      // Directly update state without triggering the settings-open flow.
      final updated = _module!.copyWith(
        settings: {..._module!.settings, 'accessibility_service': isEnabled},
      );
      await ref.read(moduleRepositoryProvider).update(updated);
      ref.invalidate(installedModulesProvider);
      if (mounted) setState(() => _module = updated);
    }
  }

  Future<void> _toggleSetting(String key, bool value) async {
    if (_module == null) return;

    // Handle native service actions for clipboard_ai module.
    if (_module!.id == 'clipboard_ai') {
      final controller = ref.read(clipboardServiceControllerProvider);

      if (key == 'persistent_notification') {
        if (value) {
          // Request notification permission first (Android 13+).
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

      if (key == 'accessibility_service') {
        if (value) {
          // Open accessibility settings for user to enable manually.
          await controller.openAccessibilitySettings();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Enable "Meow Agent" in Accessibility settings.',
                ),
                duration: Duration(seconds: 3),
              ),
            );
          }
          // Don't toggle yet — will sync when user returns.
          return;
        } else {
          // Can't programmatically disable — inform user.
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Disable the service in Accessibility settings.',
                ),
                duration: Duration(seconds: 3),
              ),
            );
          }
          await controller.openAccessibilitySettings();
          return;
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
    final updated = _module!.copyWith(enabled: value);
    await ref.read(moduleRepositoryProvider).update(updated);
    ref.invalidate(installedModulesProvider);
    setState(() => _module = updated);
  }

  Future<void> _uninstall() async {
    // Stop services before uninstalling.
    if (_module?.id == 'clipboard_ai') {
      final controller = ref.read(clipboardServiceControllerProvider);
      await controller.stopNotificationService();
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
        padding: const EdgeInsets.all(16),
        children: [
          // Module header card.
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

          // Master toggle.
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

          // Trigger settings.
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

  /// Human-readable labels for module settings.
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
          'accessibility_service': (
            'Accessibility Service',
            'Auto-detect clipboard changes (requires permission).',
          ),
        };
      default:
        return {};
    }
  }
}
