import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/local_storage_service.dart';
import '../../../core/storage/secure_storage_service.dart';
import 'llm_provider_config.dart';

/// Persists and retrieves the Master Agent's LLM provider configuration.
///
/// - Base URL and model are stored as a JSON blob in shared_preferences.
/// - API key is stored separately in flutter_secure_storage.
class SettingsRepository {
  SettingsRepository({
    required LocalStorageService local,
    required SecureStorageService secure,
  })  : _local = local,
        _secure = secure;

  static const _kProviderJson = 'meow.master_agent.provider_json';
  static const _kProviderApiKey = 'meow.master_agent.provider_api_key';

  final LocalStorageService _local;
  final SecureStorageService _secure;

  Future<LlmProviderConfig?> loadMasterAgent() async {
    final json = _local.readString(_kProviderJson);
    if (json == null) return null;
    final apiKey = await _secure.read(_kProviderApiKey) ?? '';
    return LlmProviderConfig.decodePublic(json, apiKey: apiKey);
  }

  Future<void> saveMasterAgent(LlmProviderConfig config) async {
    await _local.writeString(
      _kProviderJson,
      LlmProviderConfig.encodePublic(config),
    );
    await _secure.write(_kProviderApiKey, config.apiKey);
  }

  Future<void> clearMasterAgent() async {
    await _local.remove(_kProviderJson);
    await _secure.delete(_kProviderApiKey);
  }
}

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository(
    local: ref.watch(localStorageProvider),
    secure: ref.watch(secureStorageProvider),
  );
});

/// Reactive holder for the currently configured Master Agent.
class MasterAgentNotifier
    extends StateNotifier<AsyncValue<LlmProviderConfig?>> {
  MasterAgentNotifier(this._repo) : super(const AsyncValue.loading()) {
    _load();
  }

  final SettingsRepository _repo;

  Future<void> _load() async {
    try {
      final config = await _repo.loadMasterAgent();
      state = AsyncValue.data(config);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> save(LlmProviderConfig config) async {
    await _repo.saveMasterAgent(config);
    state = AsyncValue.data(config);
  }

  Future<void> clear() async {
    await _repo.clearMasterAgent();
    state = const AsyncValue.data(null);
  }
}

final masterAgentProvider = StateNotifierProvider<MasterAgentNotifier,
    AsyncValue<LlmProviderConfig?>>(
  (ref) => MasterAgentNotifier(ref.watch(settingsRepositoryProvider)),
);

/// Convenience boolean: has the user finished initial setup?
final isSetupCompleteProvider = Provider<bool>((ref) {
  final state = ref.watch(masterAgentProvider);
  return state.maybeWhen(
    data: (config) => config != null && config.isComplete,
    orElse: () => false,
  );
});
