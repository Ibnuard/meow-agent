import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_settings_repository.dart';
import '../../../core/storage/local_storage_service.dart';
import '../../../core/storage/meow_database.dart';
import 'vm_models.dart';

const _kVmRuntimeSnapshotKey = 'vm.runtime.snapshot';
const _kVmPluginStatesKey = 'vm.plugins.states';

/// Curated default rootfs image. Per AGENTS.md (#1 accuracy, calm UX), we
/// hide URL/checksum entry from the user. UI calls one install action; native
/// first downloads the proot binaries, then downloads this rootfs.
class VmRootfsPreset {
  const VmRootfsPreset({
    required this.url,
    required this.sha256,
    required this.version,
    this.mirrorUrls = const [],
  });

  final String url;
  final String sha256;
  final String version;

  /// Fallback download URLs tried in order if [url] fails (e.g. a 404 after
  /// Canonical prunes an old point release from `releases/`). All mirrors MUST
  /// serve the exact same bytes so [sha256] still verifies. `old-releases`
  /// keeps pruned point releases, which is the most likely recovery path.
  final List<String> mirrorUrls;

  /// All candidate URLs in priority order: primary first, then mirrors.
  List<String> get allUrls => [url, ...mirrorUrls];

  static const defaultPreset = VmRootfsPreset(
    url:
        'https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/'
        'ubuntu-base-22.04.5-base-arm64.tar.gz',
    sha256:
        '075d4abd2817a5023ab0a82f5cb314c5ec0aa64a9c0b40fd3154ca3bfdae979f',
    version: 'ubuntu-22.04.5',
    mirrorUrls: [
      // Pruned point releases land here once removed from releases/.
      'https://old-releases.ubuntu.com/releases/22.04/'
          'ubuntu-base-22.04.5-base-arm64.tar.gz',
      'http://old-releases.ubuntu.com/releases/22.04/'
          'ubuntu-base-22.04.5-base-arm64.tar.gz',
    ],
  );
}

class VmRuntimeRepository {
  const VmRuntimeRepository({LocalStorageService? storage}) : _storage = storage;

  final LocalStorageService? _storage;

  Future<LocalStorageService> _getStorage() async {
    if (_storage != null) return _storage;
    final db = MeowDatabase.instance;
    final settingsRepo = AppSettingsRepository(db);
    final allSettings = await settingsRepo.getAll();
    return LocalStorageService(settingsRepo, allSettings);
  }

  Future<VmRuntimeSnapshot> readSnapshot() async {
    final storage = await _getStorage();
    final raw = storage.readString(_kVmRuntimeSnapshotKey);
    if (raw == null || raw.isEmpty) {
      return VmRuntimeSnapshot.unavailable(
        message: 'Native VM runtime is not connected yet.',
      );
    }
    try {
      return VmRuntimeSnapshot.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return VmRuntimeSnapshot.unavailable(
        message: 'VM runtime metadata could not be read.',
      );
    }
  }

  Future<void> saveSnapshot(VmRuntimeSnapshot snapshot) async {
    final storage = await _getStorage();
    await storage.writeString(
      _kVmRuntimeSnapshotKey,
      jsonEncode(snapshot.toJson()),
    );
  }

  /// Read all known plugin states keyed by plugin id.
  Future<Map<String, VmPluginState>> readPluginStates() async {
    final storage = await _getStorage();
    final raw = storage.readString(_kVmPluginStatesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (key, value) => MapEntry(
          key,
          VmPluginState.fromJson(value as Map<String, dynamic>),
        ),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> savePluginState(VmPluginState state) async {
    final storage = await _getStorage();
    final current = await readPluginStates();
    current[state.pluginId] = state;
    final encoded = current.map(
      (key, value) => MapEntry(key, value.toJson()),
    );
    await storage.writeString(_kVmPluginStatesKey, jsonEncode(encoded));
  }
}

final vmRuntimeRepositoryProvider = Provider<VmRuntimeRepository>((ref) {
  return VmRuntimeRepository(storage: ref.watch(localStorageProvider));
});

final vmRuntimeSnapshotProvider = FutureProvider<VmRuntimeSnapshot>((ref) {
  return ref.watch(vmRuntimeRepositoryProvider).readSnapshot();
});

final vmPluginStatesProvider = FutureProvider<Map<String, VmPluginState>>((ref) {
  return ref.watch(vmRuntimeRepositoryProvider).readPluginStates();
});
