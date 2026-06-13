/// Barrel file exposing all core storage Riverpod providers under stable
/// names for use by the runtime engine and other consumers.
///
/// Import this single file instead of individual repository files when you
/// need access to the core DB providers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agent_event_repository.dart';
import 'agent_memory_repository.dart';
import 'agent_repository.dart';
import 'agent_soul_repository.dart';
import 'meow_database_provider.dart';
import 'provider_repository.dart';

export 'agent_repository.dart' show Agent, AgentRepository;
export 'provider_repository.dart' show ProviderEntry, ProviderEntryRepository;
export 'agent_soul_repository.dart' show AgentSoul, AgentSoulRepository;
export 'agent_memory_repository.dart'
    show AgentMemoryEntry, AgentMemoryRepository;
export 'agent_event_repository.dart' show AgentEvent, AgentEventRepository;
export 'app_settings_repository.dart' show AppSettingsRepository;
export 'module_entry_repository.dart'
    show ModuleEntry, AgentModulePermission, ModuleEntryRepository;
export 'meow_database.dart' show MeowDatabase;
export 'meow_database_provider.dart';

// ---------------------------------------------------------------------------
// Stable provider names used by runtime_engine.dart and other consumers.
// ---------------------------------------------------------------------------

final coreAgentRepositoryProvider = Provider<AgentRepository>((ref) {
  final db = ref.read(meowDatabaseProvider);
  final repo = AgentRepository(db);
  ref.onDispose(repo.dispose);
  return repo;
});

final coreProviderEntryRepositoryProvider =
    Provider<ProviderEntryRepository>((ref) {
  final db = ref.read(meowDatabaseProvider);
  final repo = ProviderEntryRepository(db);
  ref.onDispose(repo.dispose);
  return repo;
});

final coreAgentSoulRepositoryProvider = Provider<AgentSoulRepository>((ref) {
  final db = ref.read(meowDatabaseProvider);
  final repo = AgentSoulRepository(db);
  ref.onDispose(repo.dispose);
  return repo;
});

final coreAgentMemoryRepositoryProvider =
    Provider<AgentMemoryRepository>((ref) {
  final db = ref.read(meowDatabaseProvider);
  final repo = AgentMemoryRepository(db);
  ref.onDispose(repo.dispose);
  return repo;
});

final coreAgentEventRepositoryProvider =
    Provider<AgentEventRepository>((ref) {
  final db = ref.read(meowDatabaseProvider);
  return AgentEventRepository(db);
});
