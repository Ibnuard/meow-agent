import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'api_config.dart';

/// Global API Store repository.
///
/// Persists API configurations in a shared location accessible by all agents.
/// Credentials are stored alongside configs for now (encryption layer TBD).
class ApiStoreRepository {
  ApiStoreRepository._();
  static final ApiStoreRepository instance = ApiStoreRepository._();

  List<ApiConfig>? _cache;

  /// Base directory for the global API store.
  Future<Directory> get _storeDir async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/MeowAgent/.global/api_store');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  File _registryFile(Directory dir) => File('${dir.path}/registry.json');

  /// Load all registered APIs.
  Future<List<ApiConfig>> list() async {
    if (_cache != null) return List.unmodifiable(_cache!);
    final dir = await _storeDir;
    final file = _registryFile(dir);
    if (!await file.exists()) {
      _cache = [];
      return [];
    }
    try {
      final content = await file.readAsString();
      final list = jsonDecode(content) as List;
      _cache =
          list.map((e) => ApiConfig.fromJson(e as Map<String, dynamic>)).toList();
      return List.unmodifiable(_cache!);
    } catch (_) {
      _cache = [];
      return [];
    }
  }

  /// Find an API by ID.
  Future<ApiConfig?> findById(String id) async {
    final all = await list();
    try {
      return all.firstWhere((a) => a.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Find an API by exact name (case-insensitive).
  Future<ApiConfig?> findByName(String name) async {
    final all = await list();
    final lower = name.toLowerCase();
    try {
      return all.firstWhere((a) => a.name.toLowerCase() == lower);
    } catch (_) {
      return null;
    }
  }

  /// Add or update an API config.
  Future<void> save(ApiConfig config) async {
    final all = await list();
    final mutable = all.toList();
    final idx = mutable.indexWhere((a) => a.id == config.id);
    if (idx >= 0) {
      mutable[idx] = config;
    } else {
      mutable.add(config);
    }
    _cache = mutable;
    await _persist();
  }

  /// Remove an API by ID.
  Future<bool> remove(String id) async {
    final all = await list();
    final mutable = all.toList();
    final before = mutable.length;
    mutable.removeWhere((a) => a.id == id);
    _cache = mutable;
    await _persist();
    return mutable.length < before;
  }

  /// Persist current cache to disk.
  Future<void> _persist() async {
    final dir = await _storeDir;
    final file = _registryFile(dir);
    final json = jsonEncode(_cache!.map((c) => c.toJson()).toList());
    await file.writeAsString(json);
  }

  /// Clear in-memory cache (forces reload on next access).
  void invalidateCache() => _cache = null;
}
