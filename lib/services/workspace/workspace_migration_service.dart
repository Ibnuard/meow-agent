import 'dart:io';

import '../../core/storage/app_settings_repository.dart';
import '../../core/storage/meow_database.dart';
import 'workspace_paths.dart';

/// Migrates workspace files from internal app storage to external Documents.
///
/// Runs once on startup. Copies files from the legacy internal path to the
/// new external Documents path, then marks migration complete.
class WorkspaceMigrationService {
  static const _migrationKey = 'workspace_external_migration_completed';

  /// Check if migration has already been completed.
  static Future<bool> isMigrated() async {
    final settingsRepo = AppSettingsRepository(MeowDatabase.instance);
    final val = await settingsRepo.get(_migrationKey);
    return val == 'true';
  }

  /// Run migration for all agents.
  /// [agents] is a list of (agentId, agentName) pairs.
  static Future<void> migrate(List<({String id, String name})> agents) async {
    if (await isMigrated()) return;

    for (final agent in agents) {
      await _migrateAgent(agent.id, agent.name);
    }

    // Mark migration complete.
    final settingsRepo = AppSettingsRepository(MeowDatabase.instance);
    await settingsRepo.set(_migrationKey, 'true');
  }

  /// Migrate a single agent's workspace from internal to external.
  static Future<void> _migrateAgent(String agentId, String agentName) async {
    final legacyDir = await WorkspacePaths.getLegacyWorkspaceDir(agentId);
    if (!await legacyDir.exists()) return;

    final externalDir = await WorkspacePaths.getAgentWorkspace(agentName);
    if (!await externalDir.exists()) {
      await externalDir.create(recursive: true);
    }

    // Copy each workspace file (don't overwrite if external already exists).
    const files = ['SOUL.md', 'MEMORY.md', 'SKILLS.md', 'HEARTBEAT.md'];
    for (final filename in files) {
      final source = File('${legacyDir.path}/$filename');
      final target = File('${externalDir.path}/$filename');

      if (await source.exists() && !await target.exists()) {
        try {
          await target.writeAsString(await source.readAsString());
        } catch (_) {
          // Non-fatal: keep internal fallback.
        }
      }
    }

    // Create subdirectories.
    await Directory('${externalDir.path}/summaries').create(recursive: true);
    await Directory('${externalDir.path}/notes').create(recursive: true);
    await Directory('${externalDir.path}/exports').create(recursive: true);
  }

  /// Force re-migration (for debugging/testing).
  static Future<void> resetMigrationFlag() async {
    final settingsRepo = AppSettingsRepository(MeowDatabase.instance);
    await settingsRepo.remove(_migrationKey);
  }
}
