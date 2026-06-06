import 'package:flutter/material.dart';

import '../../../../services/permission/permission_manager.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../data/module_model.dart';

/// Handles logic specific to the Notification Intelligence module.
mixin NotificationIntelligenceHandlerMixin<T extends StatefulWidget> on State<T> {
  ModuleModel? get module;
  AppStrings get s;
  PermissionManager get permissionManager;

  Future<void> handleNotificationIntelligenceToggle(String key, bool value) async {
    if (module == null || module!.id != 'notification_intelligence') return;

    if (key == 'allow_read' && value) {
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
          await permissionManager.openNotificationListenerSettings();
        }
      }
    }
  }
}
