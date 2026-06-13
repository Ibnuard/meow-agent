import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/permission/permission_manager.dart';
import '../../../services/permission/permission_observer.dart';
import '../../../services/permission/setting_permission_requirements.dart';
import '../../modules/data/module_repository.dart';

/// Global reconciler that auto-disables module settings whose required
/// Android permission has been revoked.
///
/// Listens to [permissionStateProvider] (updated by [PermissionObserver] on
/// every app resume). When a permission transitions away from granted, all
/// module settings that depend on it are flipped to OFF in the database.
///
/// Registered once in [MeowAgentApp.initState] — runs for the app lifetime.
class ModulePermissionReconciler {
  ModulePermissionReconciler(this._ref) {
    _sub = _ref.listen<PermissionStates>(
      permissionStateProvider,
      (_, next) => _reconcile(next),
      fireImmediately: false,
    );
  }

  final Ref _ref;
  late final ProviderSubscription<PermissionStates> _sub;
  bool _running = false;

  void dispose() => _sub.close();

  Future<void> _reconcile(PermissionStates states) async {
    if (_running) return;
    _running = true;
    try {
      final repo = _ref.read(moduleRepositoryProvider);
      final modules = await repo.getInstalled();
      var anyChanged = false;

      for (final module in modules) {
        final newSettings = <String, bool>{...module.settings};
        var changed = false;

        for (final entry in module.settings.entries) {
          if (!entry.value) continue; // already OFF — nothing to do
          final perm = requiredPermissionFor(module.id, entry.key);
          if (perm == null) continue; // not gated
          if (states[perm] == PermissionResult.granted) continue; // still OK
          // Permission revoked — auto-disable this setting.
          newSettings[entry.key] = false;
          changed = true;
        }

        if (changed) {
          await repo.update(module.copyWith(settings: newSettings));
          anyChanged = true;
        }
      }

      if (anyChanged) {
        _ref.invalidate(installedModulesProvider);
      }
    } finally {
      _running = false;
    }
  }
}

final modulePermissionReconcilerProvider =
    Provider<ModulePermissionReconciler>((ref) {
  final reconciler = ModulePermissionReconciler(ref);
  ref.onDispose(reconciler.dispose);
  return reconciler;
});
