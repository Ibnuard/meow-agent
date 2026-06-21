import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../../../services/llm/openai_compatible_client.dart';

/// Persists cumulative token usage stats per agent to SQLite.
///
/// Updated at the end of each agent turn (alongside notification push).
/// Provides accurate context pressure data even after app restart.
class TokenUsageService {
  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbDir = await getDatabasesPath();
    final dbPath = '$dbDir/meow_token_usage.db';
    return openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE token_usage (
            agent_id TEXT PRIMARY KEY,
            total_input INTEGER NOT NULL DEFAULT 0,
            total_output INTEGER NOT NULL DEFAULT 0,
            total_calls INTEGER NOT NULL DEFAULT 0,
            peak_input INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL
          )
        ''');
      },
    );
  }

  /// Load persisted stats for an agent.
  Future<TokenUsageStats?> load(String agentId) async {
    final db = await _database;
    final rows = await db.query(
      'token_usage',
      where: 'agent_id = ?',
      whereArgs: [agentId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return TokenUsageStats.fromRow(rows.first);
  }

  /// Persist current session stats for an agent.
  ///
  /// Called at the end of each agent turn. Computes cumulative totals
  /// from in-memory [OpenAiCompatibleClient.usageRecords] and upserts.
  Future<void> saveFromSession(String agentId) async {
    final records = OpenAiCompatibleClient.usageRecords;
    if (records.isEmpty) return;

    var totalInput = 0;
    var totalOutput = 0;
    var peakInput = 0;
    for (final r in records) {
      totalInput += r.inputTokens;
      totalOutput += r.outputTokens ?? 0;
      if (r.inputTokens > peakInput) peakInput = r.inputTokens;
    }

    final db = await _database;
    final existing = await db.query(
      'token_usage',
      where: 'agent_id = ?',
      whereArgs: [agentId],
      limit: 1,
    );

    if (existing.isEmpty) {
      await db.insert('token_usage', {
        'agent_id': agentId,
        'total_input': totalInput,
        'total_output': totalOutput,
        'total_calls': records.length,
        'peak_input': peakInput,
        'updated_at': DateTime.now().toIso8601String(),
      });
    } else {
      // Merge: keep the higher peak, sum totals from session.
      final old = TokenUsageStats.fromRow(existing.first);
      await db.update(
        'token_usage',
        {
          'total_input': totalInput,
          'total_output': totalOutput,
          'total_calls': records.length,
          'peak_input': peakInput > old.peakInput ? peakInput : old.peakInput,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'agent_id = ?',
        whereArgs: [agentId],
      );
    }
  }

  /// Get persisted peak input for compaction logic (cold start).
  Future<int> getPersistedPeak(String agentId) async {
    final stats = await load(agentId);
    return stats?.peakInput ?? 0;
  }

  /// Delete stats for an agent (when agent is deleted).
  Future<void> delete(String agentId) async {
    final db = await _database;
    await db.delete('token_usage', where: 'agent_id = ?', whereArgs: [agentId]);
  }
}

/// Immutable snapshot of persisted token usage for one agent.
class TokenUsageStats {
  const TokenUsageStats({
    required this.agentId,
    required this.totalInput,
    required this.totalOutput,
    required this.totalCalls,
    required this.peakInput,
    required this.updatedAt,
  });

  final String agentId;
  final int totalInput;
  final int totalOutput;
  final int totalCalls;
  final int peakInput;
  final DateTime updatedAt;

  int get totalTokens => totalInput + totalOutput;

  factory TokenUsageStats.fromRow(Map<String, dynamic> row) {
    return TokenUsageStats(
      agentId: row['agent_id'] as String,
      totalInput: row['total_input'] as int? ?? 0,
      totalOutput: row['total_output'] as int? ?? 0,
      totalCalls: row['total_calls'] as int? ?? 0,
      peakInput: row['peak_input'] as int? ?? 0,
      updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// RiverPod provider for [TokenUsageService].
final tokenUsageServiceProvider = Provider<TokenUsageService>((ref) {
  return TokenUsageService();
});
