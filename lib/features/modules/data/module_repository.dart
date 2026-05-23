import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'module_model.dart';

const _kInstalledModulesKey = 'installed_modules';

/// Repository for managing installed modules.
class ModuleRepository {
  Future<List<ModuleModel>> getInstalled() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kInstalledModulesKey) ?? [];
    return raw
        .map((s) => ModuleModel.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  Future<void> install(ModuleModel module) async {
    final modules = await getInstalled();
    // Don't duplicate.
    if (modules.any((m) => m.id == module.id)) return;
    modules.add(module.copyWith(enabled: true));
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
    final prefs = await SharedPreferences.getInstance();
    final raw = modules.map((m) => jsonEncode(m.toJson())).toList();
    await prefs.setStringList(_kInstalledModulesKey, raw);
  }
}

/// Provider for the module repository.
final moduleRepositoryProvider = Provider<ModuleRepository>(
  (ref) => ModuleRepository(),
);

/// Provider that exposes the list of installed modules.
final installedModulesProvider = FutureProvider<List<ModuleModel>>((ref) {
  return ref.read(moduleRepositoryProvider).getInstalled();
});
