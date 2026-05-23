import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/local_storage_service.dart';
import '../../../core/storage/secure_storage_service.dart';
import 'provider_config.dart';

/// CRUD repository for LLM providers.
///
/// Public fields (nickname, baseUrl, model) are stored as a JSON array in
/// shared_preferences. API keys are stored individually in secure storage
/// keyed by provider id.
class ProviderRepository {
  ProviderRepository({
    required LocalStorageService local,
    required SecureStorageService secure,
  })  : _local = local,
        _secure = secure;

  static const _kProviders = 'meow.providers_json';
  static const _kApiKeyPrefix = 'meow.provider_key.';

  final LocalStorageService _local;
  final SecureStorageService _secure;

  Future<List<ProviderConfig>> loadAll() async {
    final raw = _local.readString(_kProviders);
    if (raw == null) return [];

    final jsonList = ProviderConfig.decodeList(raw);
    final providers = <ProviderConfig>[];
    for (final json in jsonList) {
      final id = json['id'] as String;
      final apiKey = await _secure.read('$_kApiKeyPrefix$id') ?? '';
      providers.add(ProviderConfig.fromPublicJson(json, apiKey: apiKey));
    }
    return providers;
  }

  Future<void> save(ProviderConfig provider) async {
    final all = await loadAll();
    final idx = all.indexWhere((p) => p.id == provider.id);
    if (idx >= 0) {
      all[idx] = provider;
    } else {
      all.add(provider);
    }
    await _persist(all);
    await _secure.write('$_kApiKeyPrefix${provider.id}', provider.apiKey);
  }

  Future<void> delete(String id) async {
    final all = await loadAll();
    all.removeWhere((p) => p.id == id);
    await _persist(all);
    await _secure.delete('$_kApiKeyPrefix$id');
  }

  Future<void> _persist(List<ProviderConfig> list) async {
    await _local.writeString(_kProviders, ProviderConfig.encodeList(list));
  }
}

final providerRepositoryProvider = Provider<ProviderRepository>((ref) {
  return ProviderRepository(
    local: ref.watch(localStorageProvider),
    secure: ref.watch(secureStorageProvider),
  );
});

/// Reactive list of all saved providers.
class ProviderListNotifier extends StateNotifier<AsyncValue<List<ProviderConfig>>> {
  ProviderListNotifier(this._repo) : super(const AsyncValue.loading()) {
    load();
  }

  final ProviderRepository _repo;

  Future<void> load() async {
    try {
      final list = await _repo.loadAll();
      state = AsyncValue.data(list);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
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
}

final providerListProvider =
    StateNotifierProvider<ProviderListNotifier, AsyncValue<List<ProviderConfig>>>(
  (ref) => ProviderListNotifier(ref.watch(providerRepositoryProvider)),
);
