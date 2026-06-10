import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/agents/data/agent_model.dart';
import '../../features/modules/data/module_model.dart';
import '../../features/providers/data/provider_config.dart';

class MeowConfigException implements Exception {
  const MeowConfigException(this.message);
  final String message;

  @override
  String toString() => message;
}

class MeowConfigPatchResult {
  const MeowConfigPatchResult({
    required this.backupId,
    required this.changedPaths,
    required this.configHash,
  });

  final String backupId;
  final List<String> changedPaths;
  final String configHash;
}

class MeowConfigRepository {
  MeowConfigRepository({Directory? root}) : _rootOverride = root;

  static const schemaVersion = 1;
  static Map<String, dynamic>? _cache;

  final Directory? _rootOverride;

  Future<Map<String, dynamic>> ensureLoaded() async {
    final file = await _file();
    if (!await file.exists()) {
      final config = _defaultConfig();
      await _writeAtomic(file, config);
      _cache = config;
      return Map<String, dynamic>.from(config);
    }
    try {
      final config = _decode(await file.readAsString());
      _validate(config);
      _cache = config;
      return Map<String, dynamic>.from(config);
    } catch (_) {
      final restored = await _restoreLatestValidBackup();
      if (restored != null) return restored;
      final config = _defaultConfig();
      await _writeAtomic(file, config);
      _cache = config;
      return Map<String, dynamic>.from(config);
    }
  }

  Map<String, dynamic> loadSync() {
    final config = _cache;
    if (config == null) return _defaultConfig();
    return jsonDecode(jsonEncode(config)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> read() => ensureLoaded();

  Future<void> importLegacyIfEmpty({
    String? agentsJson,
    String? providersJson,
    List<String>? modulesJson,
    String? language,
    String? theme,
  }) async {
    final config = await ensureLoaded();
    final prefs = Map<String, dynamic>.from(config['prefs'] as Map);
    if (language != null &&
        language.isNotEmpty &&
        prefs['language'] == 'system') {
      prefs['language'] = language;
    }
    if (theme != null && theme.isNotEmpty && prefs['theme'] == 'dark') {
      prefs['theme'] = theme;
    }
    final hasConfigState =
        (config['agents'] as List).isNotEmpty ||
        (config['providers'] as List).isNotEmpty ||
        (config['modules'] as Map).isNotEmpty;

    final agents = hasConfigState || agentsJson == null
        ? <Map<String, dynamic>>[]
        : (jsonDecode(agentsJson) as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
    final providers = hasConfigState || providersJson == null
        ? <Map<String, dynamic>>[]
        : (jsonDecode(providersJson) as List).whereType<Map>().map((m) {
            final provider = Map<String, dynamic>.from(m)..remove('apiKey');
            final id = provider['id'];
            if (id is String && id.isNotEmpty) {
              provider['apiKeyRef'] = 'secure://$id';
            }
            return provider;
          }).toList();
    final modules = <String, dynamic>{};
    if (!hasConfigState) {
      for (final raw in modulesJson ?? const <String>[]) {
        final module = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final id = module['id'];
        if (id is String && id.isNotEmpty) modules[id] = module;
      }
    }
    final ops = <Map<String, dynamic>>[
      {'op': 'replace', 'path': '/prefs', 'value': prefs},
      if (!hasConfigState)
        {'op': 'replace', 'path': '/agents', 'value': agents},
      if (!hasConfigState)
        {'op': 'replace', 'path': '/providers', 'value': providers},
      if (!hasConfigState)
        {'op': 'replace', 'path': '/modules', 'value': modules},
      if (!hasConfigState && agents.isNotEmpty)
        {
          'op': 'replace',
          'path': '/activeAgentId',
          'value': agents.first['id'],
        },
      if (!hasConfigState && providers.isNotEmpty)
        {
          'op': 'replace',
          'path': '/activeProviderId',
          'value': providers.first['id'],
        },
    ];
    if (ops.length == 1 && jsonEncode(prefs) == jsonEncode(config['prefs'])) {
      return;
    }
    await patch(ops);
  }

  Future<MeowConfigPatchResult> patch(
    List<Map<String, dynamic>> operations,
  ) async {
    final current = await ensureLoaded();
    final backupId = await _backup(current);
    final next = jsonDecode(jsonEncode(current)) as Map<String, dynamic>;
    final changed = <String>[];
    try {
      for (final op in operations) {
        final path = (op['path'] as String? ?? '').trim();
        if (path.isEmpty || !path.startsWith('/')) {
          throw const MeowConfigException('Patch path must start with /.');
        }
        _apply(next, op);
        changed.add(path);
      }
      _validate(next);
      final file = await _file();
      await _writeAtomic(file, next);
      _cache = next;
      return MeowConfigPatchResult(
        backupId: backupId,
        changedPaths: changed,
        configHash: base64Url
            .encode(utf8.encode(jsonEncode(next)))
            .substring(0, 16),
      );
    } catch (_) {
      await _writeAtomic(await _file(), current);
      _cache = current;
      rethrow;
    }
  }

  List<AgentModel> loadAgents() {
    final raw = loadSync()['agents'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => AgentModel.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<void> saveAgent(AgentModel agent) async {
    final agents = loadAgents();
    final idx = agents.indexWhere((a) => a.id == agent.id);
    if (idx < 0) {
      agents.add(agent);
    } else {
      agents[idx] = agent;
    }
    await patch([
      {
        'op': 'replace',
        'path': '/agents',
        'value': agents.map((a) => a.toJson()).toList(),
      },
      if (activeAgentId == null)
        {'op': 'replace', 'path': '/activeAgentId', 'value': agent.id},
    ]);
  }

  Future<void> deleteAgent(String id) async {
    final agents = loadAgents()..removeWhere((a) => a.id == id);
    await patch([
      {
        'op': 'replace',
        'path': '/agents',
        'value': agents.map((a) => a.toJson()).toList(),
      },
      if (activeAgentId == id)
        {
          'op': 'replace',
          'path': '/activeAgentId',
          'value': agents.isEmpty ? null : agents.first.id,
        },
    ]);
  }

  Future<List<ProviderConfig>> loadProviders({
    required Future<String?> Function(String key) readSecret,
  }) async {
    await ensureLoaded();
    final raw = loadSync()['providers'];
    if (raw is! List) return const [];
    final out = <ProviderConfig>[];
    for (final item in raw.whereType<Map>()) {
      final json = Map<String, dynamic>.from(item);
      final id = json['id'] as String? ?? '';
      final apiKey = await readSecret('meow.provider_key.$id') ?? '';
      out.add(ProviderConfig.fromPublicJson(json, apiKey: apiKey));
    }
    return out;
  }

  Future<void> saveProvider(ProviderConfig provider) async {
    final providers = List<Map<String, dynamic>>.from(
      (loadSync()['providers'] as List? ?? const []).map(
        (e) => Map<String, dynamic>.from(e as Map),
      ),
    );
    final public = provider.toPublicJson()
      ..['apiKeyRef'] = 'secure://${provider.id}';
    final idx = providers.indexWhere((p) => p['id'] == provider.id);
    if (idx < 0) {
      providers.add(public);
    } else {
      providers[idx] = public;
    }
    await patch([
      {'op': 'replace', 'path': '/providers', 'value': providers},
      if (activeProviderId == null)
        {'op': 'replace', 'path': '/activeProviderId', 'value': provider.id},
    ]);
  }

  Future<void> deleteProvider(String id) async {
    final providers = List<Map<String, dynamic>>.from(
      (loadSync()['providers'] as List? ?? const []).map(
        (e) => Map<String, dynamic>.from(e as Map),
      ),
    )..removeWhere((p) => p['id'] == id);
    await patch([
      {'op': 'replace', 'path': '/providers', 'value': providers},
      if (activeProviderId == id)
        {
          'op': 'replace',
          'path': '/activeProviderId',
          'value': providers.isEmpty ? null : providers.first['id'],
        },
    ]);
  }

  Future<List<ModuleModel>> loadModules() async {
    await ensureLoaded();
    final raw = loadSync()['modules'];
    if (raw is! Map) return const [];
    return raw.values
        .whereType<Map>()
        .map((m) => ModuleModel.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<void> saveModules(List<ModuleModel> modules) async {
    await patch([
      {
        'op': 'replace',
        'path': '/modules',
        'value': {for (final m in modules) m.id: m.toJson()},
      },
    ]);
  }

  String? readPref(String key) {
    final prefs = loadSync()['prefs'];
    if (prefs is! Map) return null;
    return prefs[key]?.toString();
  }

  Future<void> writePref(String key, String value) async {
    final prefs = Map<String, dynamic>.from(
      loadSync()['prefs'] as Map? ?? const {},
    );
    prefs[key] = value;
    await patch([
      {'op': 'replace', 'path': '/prefs', 'value': prefs},
    ]);
  }

  String? get activeAgentId => loadSync()['activeAgentId'] as String?;
  String? get activeProviderId => loadSync()['activeProviderId'] as String?;

  Future<void> setActiveAgentId(String? id) async {
    if (id != null && !loadAgents().any((a) => a.id == id)) return;
    await patch([
      {'op': 'replace', 'path': '/activeAgentId', 'value': id},
    ]);
  }

  Future<void> setActiveProviderId(String? id) async {
    if (id != null) {
      final providers = loadSync()['providers'];
      if (providers is List &&
          !providers.whereType<Map>().any((p) => p['id'] == id)) {
        return;
      }
    }
    await patch([
      {'op': 'replace', 'path': '/activeProviderId', 'value': id},
    ]);
  }

  Future<File> _file() async => File('${(await _root()).path}/meow.json');

  Future<Directory> _root() async {
    if (_rootOverride != null) return _rootOverride;
    return getApplicationDocumentsDirectory();
  }

  Future<Directory> _backupDir() async {
    final dir = Directory('${(await _root()).path}/meow.backups');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> _backup(Map<String, dynamic> config) async {
    final id = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final file = File('${(await _backupDir()).path}/meow-$id.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config),
    );
    return id;
  }

  Future<Map<String, dynamic>?> _restoreLatestValidBackup() async {
    final dir = await _backupDir();
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    for (final backup in files) {
      try {
        final config = _decode(await backup.readAsString());
        _validate(config);
        await _writeAtomic(await _file(), config);
        _cache = config;
        return Map<String, dynamic>.from(config);
      } catch (_) {}
    }
    return null;
  }

  Map<String, dynamic> _decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const MeowConfigException('meow.json must be an object.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Map<String, dynamic> _defaultConfig() => {
    'schemaVersion': schemaVersion,
    'activeAgentId': null,
    'activeProviderId': null,
    'prefs': {'language': 'system', 'theme': 'dark'},
    'providers': <Map<String, dynamic>>[],
    'agents': <Map<String, dynamic>>[],
    'modules': <String, dynamic>{},
  };

  void _validate(Map<String, dynamic> config) {
    if (config['schemaVersion'] != schemaVersion) {
      throw const MeowConfigException('Unsupported meow.json schemaVersion.');
    }
    if (config['prefs'] is! Map ||
        config['providers'] is! List ||
        config['agents'] is! List ||
        config['modules'] is! Map) {
      throw const MeowConfigException('Invalid meow.json shape.');
    }
    final providers = (config['providers'] as List).whereType<Map>().toList();
    final providerIds = providers
        .map((p) => p['id'])
        .whereType<String>()
        .toSet();
    final agents = (config['agents'] as List).whereType<Map>().toList();
    final agentIds = agents.map((a) => a['id']).whereType<String>().toSet();
    if (agentIds.length != agents.length) {
      throw const MeowConfigException('Duplicate or missing agent id.');
    }
    if (providerIds.length != providers.length) {
      throw const MeowConfigException('Duplicate or missing provider id.');
    }
    for (final provider in providers) {
      if (provider.containsKey('apiKey')) {
        throw const MeowConfigException(
          'Provider secrets are not allowed in meow.json.',
        );
      }
    }
    final activeAgentId = config['activeAgentId'];
    if (activeAgentId is String &&
        activeAgentId.isNotEmpty &&
        !agentIds.contains(activeAgentId)) {
      throw const MeowConfigException(
        'activeAgentId must reference an existing agent.',
      );
    }
    final activeProviderId = config['activeProviderId'];
    if (activeProviderId is String &&
        activeProviderId.isNotEmpty &&
        !providerIds.contains(activeProviderId)) {
      throw const MeowConfigException(
        'activeProviderId must reference an existing provider.',
      );
    }
  }

  void _apply(Map<String, dynamic> doc, Map<String, dynamic> op) {
    final kind = op['op'] as String? ?? '';
    if (kind != 'add' && kind != 'replace' && kind != 'remove') {
      throw const MeowConfigException('Unsupported patch op.');
    }
    final parts = (op['path'] as String)
        .split('/')
        .skip(1)
        .map(_unescape)
        .toList();
    if (parts.isEmpty) throw const MeowConfigException('Patch path is empty.');
    dynamic target = doc;
    for (final part in parts.take(parts.length - 1)) {
      target = _child(target, part);
    }
    final last = parts.last;
    if (target is Map<String, dynamic>) {
      if (kind == 'remove') {
        target.remove(last);
      } else {
        target[last] = op['value'];
      }
      return;
    }
    if (target is List) {
      if (last == '-' && kind == 'add') {
        target.add(op['value']);
        return;
      }
      final index = int.tryParse(last);
      if (index == null || index < 0 || index >= target.length) {
        throw const MeowConfigException('Invalid list patch index.');
      }
      if (kind == 'remove') {
        target.removeAt(index);
      } else {
        target[index] = op['value'];
      }
      return;
    }
    throw const MeowConfigException('Patch target is not mutable.');
  }

  dynamic _child(dynamic target, String part) {
    if (target is Map<String, dynamic>) return target[part];
    if (target is List) {
      final index = int.tryParse(part);
      if (index == null || index < 0 || index >= target.length) {
        throw const MeowConfigException('Invalid list patch index.');
      }
      return target[index];
    }
    throw const MeowConfigException('Patch path cannot be resolved.');
  }

  String _unescape(String part) =>
      part.replaceAll('~1', '/').replaceAll('~0', '~');

  Future<void> _writeAtomic(File file, Map<String, dynamic> config) async {
    final tmp = File('${file.path}.tmp');
    if (!await file.parent.exists()) await file.parent.create(recursive: true);
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(config));
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }
}

final meowConfigRepositoryProvider = Provider<MeowConfigRepository>((ref) {
  return MeowConfigRepository();
});
