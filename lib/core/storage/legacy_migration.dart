import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../features/modules/data/module_model.dart';
import 'app_settings_repository.dart';
import 'module_entry_repository.dart';

/// One-shot migration that pulls preferences and modules out of legacy
/// SharedPreferences storage into the SQLite `app_settings` and `modules`
/// tables. Idempotent — gated by `migration.legacy_v1_completed` in
/// `app_settings`, runs at most once per install.
///
/// Agents and providers were migrated in an earlier release (when their
/// SQLite repositories were introduced) and are not handled here.
class LegacyMigration {
  static const _completionKey = 'migration.legacy_v1_completed';

  /// Run the migration if not already completed. Always returns cleanly —
  /// individual key failures are logged-and-skipped, never thrown.
  static Future<void> runOnce({
    required SharedPreferences prefs,
    required AppSettingsRepository settings,
    required ModuleEntryRepository modules,
  }) async {
    if (await settings.get(_completionKey) == 'true') return;

    // ── Prefs ──────────────────────────────────────────────────────────────
    final theme = prefs.getString('meow.theme_mode');
    final lang = prefs.getString('meow.app.language');
    if (theme != null &&
        theme.isNotEmpty &&
        await settings.get('prefs.theme') == null) {
      await settings.set('prefs.theme', theme);
    }
    if (lang != null &&
        lang.isNotEmpty &&
        await settings.get('prefs.language') == null) {
      await settings.set('prefs.language', lang);
    }

    // ── Modules ────────────────────────────────────────────────────────────
    // Only seed the modules table when it's still empty — otherwise an
    // existing SQLite-backed install would clobber its current state.
    final existing = await modules.listAll();
    if (existing.isEmpty) {
      final raw = prefs.getStringList('installed_modules') ?? const [];
      for (final encoded in raw) {
        try {
          final decoded = jsonDecode(encoded) as Map<String, dynamic>;
          final m = ModuleModel.fromJson(decoded);
          await modules.upsert(m.id);
          await modules.setEnabled(m.id, m.enabled);
          await modules.setConfig(m.id, {'settings': m.settings});
        } catch (_) {
          // Skip malformed legacy rows.
        }
      }
    }

    await settings.set(_completionKey, 'true');
  }
}
