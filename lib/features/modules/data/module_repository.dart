import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/local_storage_service.dart';
import 'module_model.dart';

const _kInstalledModulesKey = 'installed_modules';

/// Repository for managing installed modules.
class ModuleRepository {
  ModuleRepository({SharedPreferences? prefs}) : _prefs = prefs;

  final SharedPreferences? _prefs;

  Future<SharedPreferences> _instance({bool reload = true}) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    // Keep direct tool reads in sync with settings changed from UI/native code.
    if (reload) {
      await prefs.reload();
    }
    return prefs;
  }

  Future<List<ModuleModel>> getInstalled() async {
    final prefs = await _instance();
    final raw = prefs.getStringList(_kInstalledModulesKey) ?? [];
    final stored = raw
        .map((s) => ModuleModel.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
    final legacyClipboardPersistentNotification = stored
        .where((m) => m.id == 'clipboard_ai')
        .map((m) => m.settings['persistent_notification'])
        .firstOrNull;
    // Legacy app_control settings are folded into device_context after the
    // module merge. Preserve user toggles so behavior doesn't silently change.
    final legacyAppControl = stored
        .where((m) => m.id == 'app_control')
        .map((m) => m.settings)
        .firstOrNull;

    // Migrate: reconcile stored settings against the current registry so the
    // UI reflects schema changes (added/removed keys) without reinstall. If a
    // stored module no longer exists in the registry (e.g. retired modules)
    // we drop it so it disappears from the installed list on next load.
    var migrated = false;
    final reconciled = <ModuleModel>[];
    for (final m in stored) {
      final spec = ModuleRegistry.available
          .where((r) => r.id == m.id)
          .firstOrNull;
      if (spec == null) {
        migrated = true;
        continue;
      }
      final merged = <String, bool>{};
      for (final entry in spec.settings.entries) {
        // Keep existing user toggles. New keys must default OFF to avoid silently
        // enabling newly shipped permissions/tools after app updates.
        if (m.id == 'notification_intelligence' &&
            entry.key == 'persistent_notification' &&
            !m.settings.containsKey(entry.key) &&
            legacyClipboardPersistentNotification != null) {
          merged[entry.key] = legacyClipboardPersistentNotification;
        } else if (m.id == 'device_context' &&
            !m.settings.containsKey(entry.key) &&
            legacyAppControl != null &&
            legacyAppControl.containsKey(entry.key)) {
          merged[entry.key] = legacyAppControl[entry.key]!;
        } else {
          merged[entry.key] = m.settings[entry.key] ?? false;
        }
      }
      if (merged.length != m.settings.length ||
          !merged.keys.every(m.settings.containsKey) ||
          m.name != spec.name ||
          m.description != spec.description ||
          m.icon != spec.icon) {
        migrated = true;
      }
      reconciled.add(
        m.copyWith(
          name: spec.name,
          description: spec.description,
          icon: spec.icon,
          settings: merged,
        ),
      );
    }
    if (migrated) {
      await _save(reconciled);
    }
    return reconciled;
  }

  Future<void> install(ModuleModel module) async {
    final modules = await getInstalled();
    // Don't duplicate.
    if (modules.any((m) => m.id == module.id)) return;

    // Installing a module only enables the module itself.
    // All per-feature permission toggles must start OFF and require explicit user opt-in.
    final disabledSettings = {
      for (final key in module.settings.keys) key: false,
    };
    modules.add(module.copyWith(enabled: true, settings: disabledSettings));
    await _save(modules);
  }

  Future<void> uninstall(String moduleId) async {
    final modules = await getInstalled();
    modules.removeWhere((m) => m.id == moduleId);
    await _save(modules);
  }

  Future<void> update(ModuleModel module) async {
    final modules = await getInstalled();
    final idx = modules.indexWhere((m) => m.id == module.id);
    if (idx >= 0) {
      modules[idx] = module;
      await _save(modules);
    }
  }

  Future<void> _save(List<ModuleModel> modules) async {
    final prefs = await _instance(reload: false);
    final raw = modules.map((m) => jsonEncode(m.toJson())).toList();
    await prefs.setStringList(_kInstalledModulesKey, raw);
  }
}

/// Provider for the module repository.
final moduleRepositoryProvider = Provider<ModuleRepository>(
  (ref) => ModuleRepository(prefs: ref.watch(sharedPreferencesProvider)),
);

/// Provider that exposes the list of installed modules.
final installedModulesProvider = FutureProvider<List<ModuleModel>>((ref) {
  return ref.read(moduleRepositoryProvider).getInstalled();
});
