import 'package:flutter/material.dart';

import '../../../../services/permission/permission_manager.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../data/module_model.dart';

/// Handles logic specific to the Device Context module.
mixin DeviceContextHandlerMixin<T extends StatefulWidget> on State<T> {
  ModuleModel? get module;
  AppStrings get s;
  PermissionManager get permissionManager;

  Future<void> handleDeviceContextToggle(String key, bool value) async {
    if (module == null || module!.id != 'device_context') return;

    if (key == 'allow_foreground_app' && value) {
      if (mounted) {
        final goSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(s.permissionRequired),
            content: Text(
              s.foregroundAppPermissionBody(s.openSettings),
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
        await permissionManager.openUsageAccessSettings();
      }
    }

    if (key == 'allow_bluetooth' && value) {
      await permissionManager.request(PermissionType.bluetoothConnect);
    }

    if (key == 'allow_dnd' && value) {
      if (mounted) {
        final goSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(s.permissionRequired),
            content: Text(
              s.dndPermissionBody(s.openSettings),
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
        await permissionManager.openNotificationPolicySettings();
      }
    }

    if (key == 'allow_network' && value) {
      await permissionManager.request(PermissionType.location);
      await permissionManager.request(PermissionType.phoneState);
    }

    if (key == 'allow_open_apps' && value) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(s.urlIntentsEnabled),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }

    if (key == 'allow_background_launch' && value) {
      final canDraw = await permissionManager.isGranted(
        PermissionType.systemAlertWindow,
      );
      if (!canDraw && mounted) {
        final goSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(s.permissionRequired),
            content: Text(
              s.overlayLaunchPermissionBody(s.openSettings),
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
        if (goSettings == true) {
          await permissionManager.request(PermissionType.systemAlertWindow);
        }
      }
    }
  }
}
