import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/widgets/meow_confirm_dialog.dart';
import '../../../../services/permission/permission_manager.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../data/clipboard_service_controller.dart';
import '../../data/module_model.dart';
import '../../data/module_repository.dart';
import '../../data/pin_storage_service.dart';
import '../../data/shizuku_status.dart';
import '../pin_input_dialog.dart';

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
  /// Called when the PIN status panel needs to refresh (pin set/changed/deleted).
  void refreshDevicePinPanel();

  Future<void> handleSuperPowerToggle(String key, bool value) async {
    if (module == null || module!.id != 'super_power') return;

    // Only run_locked_device requires Shizuku — app_agentic just needs the
    // Android Accessibility Service. Shizuku is reserved for the locked-screen
    // automation path (wake/unlock/relock).
    if (key == 'run_locked_device' && value) {
      final status = await refreshShizukuStatus();
      if (!status.isReady) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(s.shizukuSupportRequired),
              duration: const Duration(seconds: 3),
            ),
          );
        }
        return;
      }
    }

    // app_agentic requires Accessibility Service to be enabled.
    if (key == 'app_agentic' && value) {
      final accessibilityOn = await isAccessibilityEnabled();
      if (!accessibilityOn) {
        if (mounted) {
          final confirmed = await showMeowConfirmDialog(
            context,
            isId: s.isId,
            title: s.accessibilityPermTitle,
            message: s.accessibilityPermBody,
            confirmLabel: s.openSettings,
            cancelLabel: s.cancel,
            icon: Icons.accessibility_new_rounded,
            destructive: false,
          );
          if (confirmed) {
            await permissionManager.openAccessibilitySettings();
          }
        }
        // Mark pending — toggle will activate on resume if accessibility
        // is confirmed enabled after user navigates to system settings.
        pendingAppAgenticEnable = true;
        return;
      }
    }

    // run_locked_device additionally needs a stored device PIN.
    if (key == 'run_locked_device' && value) {
      final hasPin = await PinStorageService.instance.hasPin();
      if (!hasPin) {
        if (mounted) {
          final pin = await PinInputDialog.show(context, s);
          if (pin == null) return; // User cancelled
          refreshDevicePinPanel();
        }
      }
    }

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

    // If the user just tried to enable app_agentic and accessibility is now
    // confirmed, activate the toggle (flows from settings → back to app).
    if (pendingAppAgenticEnable && accessibilityEnabled) {
      settings['app_agentic'] = true;
      changed = true;
      pendingAppAgenticEnable = false;
    }

    // Always force-disable app_agentic if accessibility is off.
    // This handles: user enabled the toggle, then later disabled accessibility.
    if (!accessibilityEnabled && settings['app_agentic'] == true) {
      settings['app_agentic'] = false;
      settings['run_locked_device'] = false;
      changed = true;
      pendingAppAgenticEnable = false;
    }

    // Clear pending flag if accessibility is still not on.
    if (pendingAppAgenticEnable && !accessibilityEnabled) {
      pendingAppAgenticEnable = false;
    }

    if (settings['app_agentic'] != true) {
      if (settings['run_locked_device'] == true) {
        settings['run_locked_device'] = false;
        changed = true;
      }
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

  /// Builds the device PIN status row. Shows "[Encrypted PIN]" with an edit
  /// button when a PIN has been set. Called from the feature permissions area.
  Future<Widget?> buildDevicePinStatusPanel({required ColorScheme cs}) async {
    final hasPin = await PinStorageService.instance.hasPin();
    if (!hasPin || !mounted) return null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.primary.withValues(alpha: 0.15)),
        ),
        child: Row(
          children: [
            Icon(Icons.lock_outline, size: 18, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                s.devicePinEncrypted,
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  color: cs.onSurface,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () async {
                await PinInputDialog.show(context, s);
                if (mounted) {
                  refreshDevicePinPanel();
                }
              },
              icon: Icon(Icons.edit_outlined, size: 14, color: cs.primary),
              label: Text(
                s.devicePinEdit,
                style: TextStyle(fontSize: 12, color: cs.primary),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
