import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/module_repository.dart';
import 'device_context_models.dart';
import 'device_context_service.dart';

/// Business logic layer for Device Context tools.
/// Checks module + per-tool settings before calling native.
class DeviceContextRepository {
  DeviceContextRepository({
    required this.service,
    required this.moduleRepository,
  });

  final DeviceContextService service;
  final ModuleRepository moduleRepository;

  static const _moduleId = 'device_context';

  Future<Map<String, bool>> _settings() async {
    final modules = await moduleRepository.getInstalled();
    final mod = modules.where((m) => m.id == _moduleId).firstOrNull;
    if (mod == null || !mod.enabled) return {};
    return mod.settings;
  }

  Future<_CheckResult> _check(String settingKey) async {
    final s = await _settings();
    if (s.isEmpty) return _CheckResult.moduleDisabled;
    if (s[settingKey] == false) return _CheckResult.settingDisabled;
    return _CheckResult.ok;
  }

  Future<BatteryInfo?> getBattery() async {
    if (await _check('allow_battery') != _CheckResult.ok) return null;
    return service.getBatteryInfo();
  }

  Future<NetworkInfo?> getNetwork() async {
    if (await _check('allow_network') != _CheckResult.ok) return null;
    return service.getNetworkInfo();
  }

  Future<StorageInfo?> getStorage() async {
    if (await _check('allow_storage') != _CheckResult.ok) return null;
    return service.getStorageInfo();
  }

  Future<TimeInfo?> getTime() async {
    if (await _check('allow_time_locale') != _CheckResult.ok) return null;
    return service.getTimeInfo();
  }

  Future<LocaleInfo?> getLocale() async {
    if (await _check('allow_time_locale') != _CheckResult.ok) return null;
    return service.getLocaleInfo();
  }

  Future<ForegroundAppInfo?> getForegroundApp() async {
    if (await _check('allow_foreground_app') != _CheckResult.ok) return null;
    return service.getForegroundAppInfo();
  }

  Future<Map<String, dynamic>?> getUsageStats({int days = 7}) async {
    if (await _check('allow_foreground_app') != _CheckResult.ok) return null;
    return service.getUsageStats(days: days);
  }

  /// Returns a summary map or an error string if module is disabled.
  Future<({Map<String, dynamic>? data, String? error})> getSummary() async {
    final s = await _settings();
    if (s.isEmpty) {
      return (data: null, error: 'Device Context module is disabled');
    }

    final results = <String, dynamic>{};

    if (s['allow_battery'] != false) {
      final b = await service.getBatteryInfo();
      if (b != null) results['battery'] = b.toJson();
    }
    if (s['allow_network'] != false) {
      final n = await service.getNetworkInfo();
      if (n != null) results['network'] = n.toJson();
    }
    if (s['allow_storage'] != false) {
      final st = await service.getStorageInfo();
      if (st != null) results['storage'] = st.toJson();
    }
    if (s['allow_time_locale'] != false) {
      final t = await service.getTimeInfo();
      if (t != null) results['time'] = t.toJson();
      final l = await service.getLocaleInfo();
      if (l != null) results['locale'] = l.toJson();
    }

    return (data: results, error: null);
  }
}

enum _CheckResult { ok, moduleDisabled, settingDisabled }

final deviceContextRepositoryProvider = Provider<DeviceContextRepository>(
  (ref) => DeviceContextRepository(
    service: ref.read(deviceContextServiceProvider),
    moduleRepository: ref.read(moduleRepositoryProvider),
  ),
);
