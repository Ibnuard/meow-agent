import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/core_storage_providers.dart';
import '../../../core/storage/provider_repository.dart' as core_providers;
import '../../../core/storage/secure_storage_service.dart';
import 'provider_config.dart';

/// CRUD repository for LLM providers — backed by `meow_core.db`.
///
/// Public fields (nickname, baseUrl, models, codename, etc.) live in the
/// `providers` table. API keys are stored in flutter_secure_storage keyed
/// by provider id; the `api_key_ref` column holds an opaque token used to
/// look up the real key.
class ProviderRepository {
  ProviderRepository({
    required MeowDatabase db,
    required SecureStorageService secure,
  }) : _db = db,
       _secure = secure;

  static const _kApiKeyPrefix = 'meow.provider_key.';

  final MeowDatabase _db;
  final SecureStorageService _secure;

  Future<List<ProviderConfig>> loadAll() async {
    final db = await _db.database;
    final rows = await db.query('providers', orderBy: 'created_at ASC');
    final providers = <ProviderConfig>[];
    for (final row in rows) {
      final id = row['id'] as String;
      final apiKey = await _secure.read('$_kApiKeyPrefix$id') ?? '';
      providers.add(_fromRow(row, apiKey: apiKey));
    }
    return providers;
  }

  Future<ProviderConfig?> getById(String id) async {
    final db = await _db.database;
    final rows = await db.query(
      'providers',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    final apiKey = await _secure.read('$_kApiKeyPrefix$id') ?? '';
    return _fromRow(rows.first, apiKey: apiKey);
  }

  /// Saves a provider. Upserts: inserts if new, updates if existing.
  /// API key is written to secure storage separately.
  Future<void> save(ProviderConfig provider) async {
    final db = await _db.database;
    final existing = await db.query(
      'providers',
      where: 'id = ?',
      whereArgs: [provider.id],
      limit: 1,
    );
    final now = DateTime.now().toIso8601String();
    final isNew = existing.isEmpty;

    final modelsJson = jsonEncode(provider.models);
    final visionJson = jsonEncode(provider.visionModels);
    final fcJson = jsonEncode(provider.functionCallingModels);

    final values = <String, Object?>{
      'nickname': provider.nickname,
      'base_url': provider.baseUrl,
      'api_key_ref': '$_kApiKeyPrefix${provider.id}',
      'model_default': provider.model,
      'display_code': provider.displayCode,
      'codename': provider.codename,
      'models_json': modelsJson,
      'vision_models_json': visionJson,
      'function_calling_models_json': fcJson,
      'updated_at': now,
    };

    if (isNew) {
      values['id'] = provider.id;
      values['created_at'] = now;
      await db.insert('providers', values);
    } else {
      await db.update(
        'providers',
        values,
        where: 'id = ?',
        whereArgs: [provider.id],
      );
    }
    // Persist the actual API key in secure storage.
    await _secure.write('$_kApiKeyPrefix${provider.id}', provider.apiKey);
  }

  Future<void> delete(String id) async {
    final db = await _db.database;
    await db.delete('providers', where: 'id = ?', whereArgs: [id]);
    await _secure.delete('$_kApiKeyPrefix$id');
  }

  static ProviderConfig _fromRow(
    Map<String, dynamic> row, {
    required String apiKey,
  }) {
    List<String> decodeList(String? raw) {
      if (raw == null || raw.isEmpty) return const [];
      try {
        final list = jsonDecode(raw) as List;
        return list.map((e) => e.toString()).toList();
      } catch (_) {
        return const [];
      }
    }

    return ProviderConfig(
      id: row['id'] as String,
      nickname: (row['nickname'] as String?) ?? '',
      baseUrl: (row['base_url'] as String?) ?? '',
      apiKey: apiKey,
      model: (row['model_default'] as String?) ?? '',
      models: decodeList(row['models_json'] as String?),
      visionModels: decodeList(row['vision_models_json'] as String?),
      functionCallingModels:
          decodeList(row['function_calling_models_json'] as String?),
      codename: (row['codename'] as String?)?.trim(),
    );
  }
}

final providerRepositoryProvider = Provider<ProviderRepository>((ref) {
  return ProviderRepository(
    db: ref.read(meowDatabaseProvider),
    secure: ref.watch(secureStorageProvider),
  );
});

/// Reactive list of all saved providers.
///
/// Subscribes to the core repository's broadcast stream so writes from
/// LLM tool plugins (`provider.create`, `provider.delete`, etc.) reach the
/// UI without an explicit reload. Direct UI mutations via [save] / [delete]
/// also reload synchronously to give callers a guarantee.
class ProviderListNotifier
    extends StateNotifier<AsyncValue<List<ProviderConfig>>> {
  ProviderListNotifier(
    this._repo,
    core_providers.ProviderEntryRepository coreRepo,
  ) : super(const AsyncValue.loading()) {
    load();
    _coreSub = coreRepo.watchAll().listen((_) => load());
  }

  final ProviderRepository _repo;
  StreamSubscription<List<core_providers.ProviderEntry>>? _coreSub;

  Future<void> load() async {
    try {
      final list = await _repo.loadAll();
      if (mounted) state = AsyncValue.data(list);
    } catch (e, st) {
      if (mounted) state = AsyncValue.error(e, st);
    }
  }

  Future<void> save(ProviderConfig provider) async {
    await _repo.save(provider);
    await load();
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    await load();
  }

  @override
  void dispose() {
    _coreSub?.cancel();
    super.dispose();
  }
}

final providerListProvider =
    StateNotifierProvider<
      ProviderListNotifier,
      AsyncValue<List<ProviderConfig>>
    >(
      (ref) => ProviderListNotifier(
        ref.watch(providerRepositoryProvider),
        ref.watch(coreProviderEntryRepositoryProvider),
      ),
    );
