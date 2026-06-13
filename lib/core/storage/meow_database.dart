import 'package:sqflite/sqflite.dart';

/// Single source-of-truth SQLite database for Meow Agent core entities.
///
/// Replaces the previous `meow.json` + workspace markdown architecture.
/// Stores: app settings, providers, agents, agent soul/memory/events,
/// modules, and per-agent module permissions.
///
/// Schema is structured (not blob JSON) so the runtime can read/write
/// individual fields atomically. Reactive watchers on top of these tables
/// (see repository layer) eliminate the stale-state verification bugs that
/// plagued the file-based design.
///
/// File: `<databases>/meow_core.db`. Other domain DBs (chat, notes, calendar)
/// remain separate to keep this one focused on identity + config state.
class MeowDatabase {
  MeowDatabase._();
  static final MeowDatabase instance = MeowDatabase._();

  static const _dbName = 'meow_core.db';
  static const _schemaVersion = 1;

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = '$dir/$_dbName';
    return openDatabase(
      path,
      version: _schemaVersion,
      onConfigure: (db) async {
        // Foreign keys are off by default in SQLite — enable so cascade
        // deletes (agent → soul/memory/events) work correctly.
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _createSchema(db);
      },
    );
  }

  Future<void> _createSchema(Database db) async {
    final batch = db.batch();

    // -----------------------------------------------------------------------
    // App-level settings (language, active agent id, theme, autoCompact, ...)
    // -----------------------------------------------------------------------
    batch.execute('''
      CREATE TABLE app_settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    // -----------------------------------------------------------------------
    // Providers (LLM endpoints).
    // api_key is stored encrypted via flutter_secure_storage; this column
    // holds an opaque token reference, not the raw key.
    //
    // models_json / vision_models_json / function_calling_models_json store
    // arrays of model names that the provider supports — needed by the UI
    // model picker. JSON-encoded for atomic read/write.
    // -----------------------------------------------------------------------
    batch.execute('''
      CREATE TABLE providers (
        id                            TEXT PRIMARY KEY,
        nickname                      TEXT NOT NULL,
        base_url                      TEXT NOT NULL,
        api_key_ref                   TEXT NOT NULL,
        model_default                 TEXT NOT NULL,
        display_code                  TEXT,
        codename                      TEXT,
        models_json                   TEXT,
        vision_models_json            TEXT,
        function_calling_models_json  TEXT,
        created_at                    TEXT NOT NULL,
        updated_at                    TEXT NOT NULL
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_providers_nickname ON providers(nickname)',
    );

    // -----------------------------------------------------------------------
    // Agents.
    // icon_key / color_key store stable preset keys for the avatar UI.
    // -----------------------------------------------------------------------
    batch.execute('''
      CREATE TABLE agents (
        id            TEXT PRIMARY KEY,
        name          TEXT NOT NULL,
        provider_id   TEXT NOT NULL REFERENCES providers(id) ON DELETE RESTRICT,
        model         TEXT,
        max_context   INTEGER NOT NULL DEFAULT 8191,
        auto_compact  INTEGER NOT NULL DEFAULT 1,
        icon_key      TEXT,
        color_key     TEXT,
        created_at    TEXT NOT NULL,
        updated_at    TEXT NOT NULL
      )
    ''');
    batch.execute('CREATE UNIQUE INDEX idx_agents_name ON agents(name)');
    batch.execute(
      'CREATE INDEX idx_agents_provider ON agents(provider_id)',
    );

    // -----------------------------------------------------------------------
    // Agent SOUL — structured identity. Replaces SOUL.md.
    // One row per agent. Created at agent creation, updated atomically.
    // -----------------------------------------------------------------------
    batch.execute('''
      CREATE TABLE agent_soul (
        agent_id            TEXT PRIMARY KEY
                            REFERENCES agents(id) ON DELETE CASCADE,
        user_name           TEXT,
        user_nickname       TEXT,
        preferred_language  TEXT,
        timezone            TEXT,
        work_role           TEXT,
        main_project        TEXT,
        communication_style TEXT,
        design_preference   TEXT,
        persona             TEXT,
        persona_meta        TEXT,
        updated_at          TEXT NOT NULL
      )
    ''');

    // -----------------------------------------------------------------------
    // Agent MEMORY — append-only long-term facts. Replaces MEMORY.md.
    // category: fact | preference | bookmark | session
    // -----------------------------------------------------------------------
    batch.execute('''
      CREATE TABLE agent_memory (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        agent_id   TEXT NOT NULL
                   REFERENCES agents(id) ON DELETE CASCADE,
        category   TEXT NOT NULL DEFAULT 'fact',
        content    TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_memory_agent ON agent_memory(agent_id, created_at DESC)',
    );
    batch.execute(
      'CREATE INDEX idx_memory_category ON agent_memory(agent_id, category)',
    );

    // -----------------------------------------------------------------------
    // Agent EVENTS — heartbeat / activity stream. Replaces HEARTBEAT.md.
    // event_type: task_completed | task_started | error | idle | ...
    // -----------------------------------------------------------------------
    batch.execute('''
      CREATE TABLE agent_events (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        agent_id    TEXT NOT NULL
                    REFERENCES agents(id) ON DELETE CASCADE,
        event_type  TEXT NOT NULL,
        state       TEXT,
        task        TEXT,
        last_tool   TEXT,
        last_result TEXT,
        created_at  TEXT NOT NULL
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_events_agent ON agent_events(agent_id, created_at DESC)',
    );
    batch.execute(
      'CREATE INDEX idx_events_type ON agent_events(agent_id, event_type)',
    );

    // -----------------------------------------------------------------------
    // Modules — installed plugins, global enable/config.
    // -----------------------------------------------------------------------
    batch.execute('''
      CREATE TABLE modules (
        id           TEXT PRIMARY KEY,
        enabled      INTEGER NOT NULL DEFAULT 1,
        config_json  TEXT,
        installed_at TEXT NOT NULL
      )
    ''');

    // -----------------------------------------------------------------------
    // Per-agent module permissions and overrides.
    // -----------------------------------------------------------------------
    batch.execute('''
      CREATE TABLE agent_module_permissions (
        agent_id    TEXT NOT NULL
                    REFERENCES agents(id) ON DELETE CASCADE,
        module_id   TEXT NOT NULL
                    REFERENCES modules(id) ON DELETE CASCADE,
        enabled     INTEGER NOT NULL DEFAULT 1,
        config_json TEXT,
        PRIMARY KEY (agent_id, module_id)
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_amp_agent ON agent_module_permissions(agent_id)',
    );
    batch.execute(
      'CREATE INDEX idx_amp_module ON agent_module_permissions(module_id)',
    );

    await batch.commit(noResult: true);
  }

  /// Test-only: wipe and recreate. Used by widget tests / golden suite.
  Future<void> resetForTesting() async {
    final db = await database;
    final batch = db.batch();
    batch.execute('DROP TABLE IF EXISTS agent_module_permissions');
    batch.execute('DROP TABLE IF EXISTS modules');
    batch.execute('DROP TABLE IF EXISTS agent_events');
    batch.execute('DROP TABLE IF EXISTS agent_memory');
    batch.execute('DROP TABLE IF EXISTS agent_soul');
    batch.execute('DROP TABLE IF EXISTS agents');
    batch.execute('DROP TABLE IF EXISTS providers');
    batch.execute('DROP TABLE IF EXISTS app_settings');
    await batch.commit(noResult: true);
    await _createSchema(db);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
