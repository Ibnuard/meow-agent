import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/permission/permission_manager.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../data/clipboard_service_controller.dart';
import '../../data/module_model.dart';

/// Handles logic specific to the Clipboard AI module.
mixin ClipboardAiHandlerMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  ModuleModel? get module;
  AppStrings get s;
  PermissionManager get permissionManager;

  Future<void> handleClipboardAiToggle(String key, bool value) async {
    if (module == null || module!.id != 'clipboard_ai') return;

    if (key == 'persistent_notification') {
      if (value) {
        final granted = await permissionManager.request(
              PermissionType.notification,
            ) ==
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
}
