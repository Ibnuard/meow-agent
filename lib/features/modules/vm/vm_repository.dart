import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/local_storage_service.dart';
import 'vm_models.dart';

const _kVmRuntimeSnapshotKey = 'vm.runtime.snapshot';
const _kVmPluginStatesKey = 'vm.plugins.states';

/// Curated default rootfs image. Per AGENTS.md (#1 accuracy, calm UX), we
/// hide URL/checksum entry from the user. The native side ships a verified
/// preset; UI just calls install with no parameters.
///
/// The native downloader is the source of truth for the actual URL/checksum.
/// These values are passed through for the MVP service layer; the native
/// implementation may override or ignore them when it ships.
class VmRootfsPreset {
  const VmRootfsPreset({
    required this.url,
    required this.sha256,
    required this.version,
  });

  final String url;
  final String sha256;
  final String version;

  static const defaultPreset = VmRootfsPreset(
    url:
        'https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/'
        'ubuntu-base-22.04.5-base-arm64.tar.gz',
    sha256:
        '075d4abd2817a5023ab0a82f5cb314c5ec0aa64a9c0b40fd3154ca3bfdae979f',
    version: 'ubuntu-22.04.5',
  );
}

class VmRuntimeRepository {
  const VmRuntimeRepository({SharedPreferences? prefs}) : _prefs = prefs;

  final SharedPreferences? _prefs;

  Future<SharedPreferences> _instance({bool reload = true}) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    if (reload) await prefs.reload();
    return prefs;
  }

  Future<VmRuntimeSnapshot> readSnapshot() async {
    final prefs = await _instance();
    final raw = prefs.getString(_kVmRuntimeSnapshotKey);
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
    final prefs = await _instance(reload: false);
    await prefs.setString(
      _kVmRuntimeSnapshotKey,
      jsonEncode(snapshot.toJson()),
    );
  }

  /// Read all known plugin states keyed by plugin id.
  Future<Map<String, VmPluginState>> readPluginStates() async {
    final prefs = await _instance();
    final raw = prefs.getString(_kVmPluginStatesKey);
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
    final prefs = await _instance(reload: false);
    final current = await readPluginStates();
    current[state.pluginId] = state;
    final encoded = current.map(
      (key, value) => MapEntry(key, value.toJson()),
    );
    await prefs.setString(_kVmPluginStatesKey, jsonEncode(encoded));
  }
}

final vmRuntimeRepositoryProvider = Provider<VmRuntimeRepository>((ref) {
  return VmRuntimeRepository(prefs: ref.watch(sharedPreferencesProvider));
});

final vmRuntimeSnapshotProvider = FutureProvider<VmRuntimeSnapshot>((ref) {
  return ref.watch(vmRuntimeRepositoryProvider).readSnapshot();
});

final vmPluginStatesProvider = FutureProvider<Map<String, VmPluginState>>((ref) {
  return ref.watch(vmRuntimeRepositoryProvider).readPluginStates();
});
