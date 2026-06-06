import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/permission/permission_manager.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../data/clipboard_service_controller.dart';
import '../../data/module_model.dart';
import '../../data/module_repository.dart';
import '../../data/shizuku_status.dart';

/// Handles logic specific to the Super Power module.
mixin SuperPowerHandlerMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  ModuleModel? get module;
  AppStrings get s;
  PermissionManager get permissionManager;
  @override
  WidgetRef get ref;

  ShizukuStatus? get shizukuStatus;
  set shizukuStatus(ShizukuStatus? value);
  bool get checkingShizuku;
  set checkingShizuku(bool value);
  bool get requestingShizukuPermission;
  set requestingShizukuPermission(bool value);
  bool get pendingAppAgenticEnable;
  set pendingAppAgenticEnable(bool value);

  void onModuleUpdated(ModuleModel updated);

  Future<void> handleSuperPowerToggle(String key, bool value) async {
    if (module == null || module!.id != 'super_power') return;

    if (key == 'overlay_bubble') {
      if (value) {
        final notifGranted = await permissionManager.request(
              PermissionType.notification,
            ) ==
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

        final canDraw = await permissionManager.isGranted(
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
          await permissionManager.request(PermissionType.systemAlertWindow);
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
  }

  Future<bool> isAccessibilityEnabled() async {
    try {
      const channel = MethodChannel('com.meowagent/shizuku');
      return await channel.invokeMethod<bool>('isAccessibilityEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<ShizukuStatus> refreshShizukuStatus() async {
    if (module == null || module!.id != 'super_power') {
      return const ShizukuStatus.unknown();
    }
    if (mounted) {
      checkingShizuku = true;
    }
    try {
      const channel = MethodChannel('com.meowagent/shizuku');
      final result = await channel.invokeMethod('getStatus');
      final data = Map<String, dynamic>.from(result as Map);
      final status = ShizukuStatus(
        available: data['shizuku_available'] == true,
        permissionGranted: data['permission_granted'] == true,
      );
      if (mounted) {
        shizukuStatus = status;
        checkingShizuku = false;
      }
      return status;
    } catch (e) {
      final status = ShizukuStatus(error: e.toString());
      if (mounted) {
        shizukuStatus = status;
        checkingShizuku = false;
      }
      return status;
    }
  }

  Future<void> requestShizukuPermission() async {
    if (requestingShizukuPermission) return;
    if (mounted) {
      requestingShizukuPermission = true;
    }
    try {
      const channel = MethodChannel('com.meowagent/shizuku');
      await channel.invokeMethod('requestPermission');
      if (mounted) {
        requestingShizukuPermission = false;
        shizukuStatus = ShizukuStatus(
          available: shizukuStatus?.available ?? false,
          permissionGranted: shizukuStatus?.permissionGranted ?? false,
          requestPending: true,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await refreshShizukuStatus();
    } catch (e) {
      if (mounted) {
        requestingShizukuPermission = false;
        shizukuStatus = ShizukuStatus(error: e.toString());
      }
    }
  }

  Future<void> syncSuperPowerPermissions() async {
    if (module == null || module!.id != 'super_power') return;
    final settings = Map<String, bool>.from(module!.settings);
    var changed = false;

    final accessibilityEnabled = await isAccessibilityEnabled();
    if (pendingAppAgenticEnable && accessibilityEnabled) {
      settings['app_agentic'] = true;
      changed = true;
    }
    pendingAppAgenticEnable = false;

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
    final updated = module!.copyWith(settings: settings);
    await ref.read(moduleRepositoryProvider).update(updated);
    ref.invalidate(installedModulesProvider);
    onModuleUpdated(updated);
  }

  Widget buildShizukuStatusPanel({required ColorScheme cs}) {
    final status = shizukuStatus;
    final isChecking = checkingShizuku && status == null;
    final icon = isChecking
        ? Icons.sync_rounded
        : status?.icon ?? Icons.help_outline_rounded;
    final color = isChecking ? cs.primary : status?.color ?? cs.outline;
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
}
