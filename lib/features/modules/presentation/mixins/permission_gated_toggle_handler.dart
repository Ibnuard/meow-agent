import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/permission/permission_manager.dart';
import '../../../../services/permission/setting_permission_requirements.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../data/module_model.dart';

/// Generic mixin that gates module-setting toggles on Android runtime
/// permissions using the centralized [settingPermissionRequirements] map.
///
/// Add this mixin to any `ConsumerState` that renders module toggles.
/// Call [handlePermissionGatedToggle] at the TOP of `_toggleSetting` —
/// if it returns `false`, the toggle should NOT save (stays OFF).
///
/// Modules without entries in the map pass through silently.
mixin PermissionGatedToggleHandlerMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// Subclass must expose the current module being displayed.
  ModuleModel? get module;

  /// Subclass must expose the localized strings.
  AppStrings get s;

  /// Subclass must expose the centralized permission manager.
  PermissionManager get permissionManager;

  /// Returns `true` if the toggle may proceed to save, `false` to abort
  /// (toggle stays at its previous OFF state).
  ///
  /// Turning OFF never requires a permission check.
  Future<bool> handlePermissionGatedToggle(String key, bool value) async {
    if (!value) return true; // turning OFF — always allowed
    if (module == null) return true;

    final perm = requiredPermissionFor(module!.id, key);
    if (perm == null) return true; // not permission-gated — pass through

    // Already granted — silent allow.
    final current = await permissionManager.check(perm);
    if (current == PermissionResult.granted) return true;

    // Permanently denied — offer "Open Settings" dialog, block toggle.
    if (current == PermissionResult.permanentlyDenied) {
      await _promptOpenSettings(perm);
      return false;
    }

    // Standard request flow.
    final result = await permissionManager.request(perm);
    if (result == PermissionResult.granted) return true;

    // Denied or permanently denied after request.
    if (result == PermissionResult.permanentlyDenied) {
      await _promptOpenSettings(perm);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            s.permissionDeniedMessage(s.permissionLabel(perm.name)),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
    return false;
  }

  /// Shows a dialog explaining the permission is permanently blocked and
  /// offering to open Android system settings.
  Future<void> _promptOpenSettings(PermissionType perm) async {
    if (!mounted) return;
    final label = s.permissionLabel(perm.name);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.permissionRequired),
        content: Text(s.permissionPermanentlyDeniedBody(label)),
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
    if (go == true) {
      await permissionManager.openSettings(perm);
    }
  }
}
