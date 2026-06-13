import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'meow_database.dart';
import 'meow_database_provider.dart';

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// Immutable value object representing an LLM provider endpoint.
class ProviderEntry {
  const ProviderEntry({
    required this.id,
    required this.nickname,
    required this.baseUrl,
    required this.apiKeyRef,
    required this.modelDefault,
    this.displayCode,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String nickname;
  final String baseUrl;

  /// Opaque reference to the secure-storage key holding the real API key.
  /// Never the raw key itself.
  final String apiKeyRef;

  final String modelDefault;
  final String? displayCode;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Whether this provider has all required fields filled.
  bool get isComplete =>
      baseUrl.trim().isNotEmpty &&
      apiKeyRef.trim().isNotEmpty &&
      modelDefault.trim().isNotEmpty;

  /// Returns the effective model, preferring an agent-level override.
  String effectiveModel(String? agentModel) {
    if (agentModel != null && agentModel.trim().isNotEmpty) {
      return agentModel.trim();
    }
    return modelDefault;
  }

  ProviderEntry copyWith({
    String? nickname,
    String? baseUrl,
    String? apiKeyRef,
    String? modelDefault,
    String? displayCode,
    DateTime? updatedAt,
    bool clearDisplayCode = false,
  }) {
    return ProviderEntry(
      id: id,
      nickname: nickname ?? this.nickname,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKeyRef: apiKeyRef ?? this.apiKeyRef,
      modelDefault: modelDefault ?? this.modelDefault,
      displayCode: clearDisplayCode ? null : (displayCode ?? this.displayCode),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toRow() => {
    'id': id,
    'nickname': nickname,
    'base_url': baseUrl,
    'api_key_ref': apiKeyRef,
    'model_default': modelDefault,
    'display_code': displayCode,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory ProviderEntry.fromRow(Map<String, dynamic> row) => ProviderEntry(
    id: row['id'] as String,
    nickname: row['nickname'] as String,
    baseUrl: row['base_url'] as String,
    apiKeyRef: row['api_key_ref'] as String,
    modelDefault: row['model_default'] as String,
    displayCode: row['display_code'] as String?,
    createdAt: DateTime.parse(row['created_at'] as String),
    updatedAt: DateTime.parse(row['updated_at'] as String),
  );
}

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

/// Reactive repository for provider CRUD backed by `meow_core.db`.
class ProviderEntryRepository {
  ProviderEntryRepository(this._db);

  final MeowDatabase _db;
  final _controller = StreamController<List<ProviderEntry>>.broadcast();

  /// Real-time stream of all providers.
  Stream<List<ProviderEntry>> watchAll() async* {
    yield await getAll();
    yield* _controller.stream;
  }

  Future<List<ProviderEntry>> getAll() async {
    final db = await _db.database;
    final rows = await db.query('providers', orderBy: 'created_at ASC');
    return rows.map(ProviderEntry.fromRow).toList();
  }

  Future<ProviderEntry?> getById(String id) async {
    final db = await _db.database;
    final rows = await db.query('providers', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return ProviderEntry.fromRow(rows.first);
  }

  Future<ProviderEntry?> getByNickname(String nickname) async {
    final db = await _db.database;
    final rows = await db.query(
      'providers',
      where: 'LOWER(nickname) = ?',
      whereArgs: [nickname.trim().toLowerCase()],
    );
    if (rows.isEmpty) return null;
    return ProviderEntry.fromRow(rows.first);
  }

  /// Create a new provider. Returns the created entity.
  ///
  /// [apiKeyRef] is the key reference stored in secure storage — the raw
  /// API key must be written to [SecureStorageService] by the caller.
  Future<ProviderEntry> create({
    required String nickname,
    required String baseUrl,
    required String apiKeyRef,
    required String modelDefault,
    String? displayCode,
  }) async {
    final now = DateTime.now();
    final entry = ProviderEntry(
      id: const Uuid().v4(),
      nickname: nickname.trim(),
      baseUrl: baseUrl.trim(),
      apiKeyRef: apiKeyRef,
      modelDefault: modelDefault.trim(),
      displayCode: displayCode?.trim(),
      createdAt: now,
      updatedAt: now,
    );
    final db = await _db.database;
    await db.insert('providers', entry.toRow());
    _notify();
    return entry;
  }

  /// Update an existing provider. Returns the updated entity.
  Future<ProviderEntry> update(ProviderEntry entry) async {
    final updated = entry.copyWith(updatedAt: DateTime.now());
    final db = await _db.database;
    await db.update(
      'providers',
      updated.toRow(),
      where: 'id = ?',
      whereArgs: [updated.id],
    );
    _notify();
    return updated;
  }

  /// Delete a provider by ID.
  ///
  /// Will fail if agents still reference this provider (ON DELETE RESTRICT).
  /// Caller should reassign or delete dependent agents first.
  Future<void> delete(String id) async {
    final db = await _db.database;
    await db.delete('providers', where: 'id = ?', whereArgs: [id]);
    _notify();
  }

  void notify() => _notify();

  void _notify() async {
    _controller.add(await getAll());
  }

  void dispose() {
    _controller.close();
  }
}

// ---------------------------------------------------------------------------
// Riverpod Providers
// ---------------------------------------------------------------------------

final providerEntryRepositoryProvider = Provider<ProviderEntryRepository>((ref) {
  final db = ref.read(meowDatabaseProvider);
  final repo = ProviderEntryRepository(db);
  ref.onDispose(repo.dispose);
  return repo;
});

/// Reactive stream of all LLM providers.
final providerEntryStreamProvider = StreamProvider<List<ProviderEntry>>((ref) {
  return ref.read(providerEntryRepositoryProvider).watchAll();
});

/// Synchronous snapshot for non-async contexts.
final providerEntryListSyncProvider = Provider<List<ProviderEntry>>((ref) {
  return ref.watch(providerEntryStreamProvider).value ?? [];
});
