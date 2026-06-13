import '../../../core/storage/module_entry_repository.dart';
import '../../../core/storage/meow_database.dart';
import 'module_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Repository for managing installed modules.
///
/// Phase 7: backed by the SQLite `modules` table via [ModuleEntryRepository].
/// Display metadata (name, description, icon, default settings shape) comes
/// from [ModuleRegistry.available] at read time — only id, enabled flag, and
/// the runtime settings map are persisted.
class ModuleRepository {
  ModuleRepository([ModuleEntryRepository? entries]) : _injected = entries;

  final ModuleEntryRepository? _injected;

  /// Resolve the entry repo — prefer the injected one, fallback to a fresh
  /// instance from the singleton DB for standalone construction (e.g. from
  /// tool dispatch classes that don't have Riverpod access).
  ModuleEntryRepository get _entries =>
      _injected ?? ModuleEntryRepository(MeowDatabase.instance);

  /// Read all installed modules, joined against [ModuleRegistry] for display
  /// fields. Reconciles the stored `settings` map against the current registry
  /// shape so newly-added permission keys default to false instead of
  /// silently inheriting older defaults.
  Future<List<ModuleModel>> getInstalled() async {
    final rows = await _entries.listAll();
    final out = <ModuleModel>[];
    var migrated = false;

    // Legacy bridges across module merges: clipboard_ai's persistent flag
    // moved into notification_intelligence; app_control's settings folded
    // into device_context. Read those once before reconciliation so we can
    // preserve user toggles when the new keys are absent.
    bool? legacyClipboardPersistent;
    Map<String, bool>? legacyAppControl;
    for (final row in rows) {
      if (row.id == 'clipboard_ai') {
        legacyClipboardPersistent =
            (row.config?['settings'] as Map?)?['persistent_notification']
                as bool?;
      } else if (row.id == 'app_control') {
        final raw = (row.config?['settings'] as Map?)?.cast<String, dynamic>();
        if (raw != null) {
          legacyAppControl = {
            for (final e in raw.entries)
              if (e.value is bool) e.key: e.value as bool,
          };
        }
      }
    }

    for (final row in rows) {
      final spec =
          ModuleRegistry.available.where((r) => r.id == row.id).firstOrNull;
      if (spec == null) {
        // Retired module (or legacy clipboard_ai/app_control after merge).
        // Drop the row so it disappears from the installed list.
        await _entries.delete(row.id);
        migrated = true;
        continue;
      }

      final stored = <String, bool>{};
      final rawSettings = (row.config?['settings'] as Map?)
          ?.cast<String, dynamic>();
      if (rawSettings != null) {
        for (final e in rawSettings.entries) {
          if (e.value is bool) stored[e.key] = e.value as bool;
        }
      }

      final merged = <String, bool>{};
      for (final entry in spec.settings.entries) {
        if (spec.id == 'notification_intelligence' &&
            entry.key == 'persistent_notification' &&
            !stored.containsKey(entry.key) &&
            legacyClipboardPersistent != null) {
          merged[entry.key] = legacyClipboardPersistent;
        } else if (spec.id == 'device_context' &&
            !stored.containsKey(entry.key) &&
            legacyAppControl != null &&
            legacyAppControl.containsKey(entry.key)) {
          merged[entry.key] = legacyAppControl[entry.key]!;
        } else {
          // Existing user toggle wins; new keys default OFF so app updates
          // don't silently grant new permissions.
          merged[entry.key] = stored[entry.key] ?? false;
        }
      }

      if (merged.length != stored.length ||
          !merged.keys.every(stored.containsKey)) {
        migrated = true;
      }

      out.add(
        spec.copyWith(enabled: row.enabled, settings: merged),
      );
    }

    // Persist the reconciled settings so future reads are stable and the
    // legacy bridge fires only once.
    if (migrated) {
      for (final m in out) {
        await _entries.setConfig(m.id, {'settings': m.settings});
      }
    }
    return out;
  }

  Future<void> install(ModuleModel module) async {
    final existing = await _entries.getById(module.id);
    if (existing != null) return;

    // Installing a module only enables the module itself.
    // All per-feature permission toggles must start OFF and require explicit
    // user opt-in.
    final disabledSettings = {
      for (final key in module.settings.keys) key: false,
    };
    await _entries.upsert(module.id);
    await _entries.setEnabled(module.id, true);
    await _entries.setConfig(module.id, {'settings': disabledSettings});
  }

  Future<void> uninstall(String moduleId) async {
    await _entries.delete(moduleId);
  }

  Future<void> update(ModuleModel module) async {
    await _entries.setEnabled(module.id, module.enabled);
    await _entries.setConfig(module.id, {'settings': module.settings});
  }
}

/// Provider for the module repository.
final moduleRepositoryProvider = Provider<ModuleRepository>(
  (ref) => ModuleRepository(ref.watch(moduleEntryRepositoryProvider)),
);

/// Reactive list of installed modules — re-emits whenever the underlying
/// `modules` table changes (from UI, LLM tool, or background workflow).
final installedModulesProvider = StreamProvider<List<ModuleModel>>((ref) {
  final repo = ref.read(moduleRepositoryProvider);
  final entries = ref.read(moduleEntryRepositoryProvider);
  return entries.watchAll().asyncMap((_) => repo.getInstalled());
});
