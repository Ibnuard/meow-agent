import 'package:flutter/material.dart';

import '../../../../services/permission/permission_manager.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../data/module_model.dart';

/// Handles logic specific to the Communication module.
mixin CommunicationHandlerMixin<T extends StatefulWidget> on State<T> {
  ModuleModel? get module;
  AppStrings get s;
  PermissionManager get permissionManager;

  Future<void> handleCommunicationToggle(String key, bool value) async {
    if (module == null || module!.id != 'communication') return;

    if (value && key == 'call_enabled') {
      final result = await permissionManager.request(PermissionType.callPhone);
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

    if (value && key == 'sms_enabled') {
      final result = await permissionManager.request(PermissionType.sendSms);
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

    if (value && key == 'contact_access') {
      final result = await permissionManager.request(PermissionType.contacts);
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
}
