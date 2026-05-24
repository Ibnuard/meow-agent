import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/module_repository.dart';
import 'notification_models.dart';
import 'notification_service.dart';

/// Permission/setting check result for the notification module.
enum _NotifCheck {
  ok,
  moduleDisabled,
  settingDisabled,
  permissionMissing,
}

/// Business logic for Notification Intelligence tools.
/// Gates every call against module + per-tool settings + system permission.
class NotificationRepository {
  NotificationRepository({
    required this.service,
    required this.moduleRepository,
  });

  final NotificationService service;
  final ModuleRepository moduleRepository;

  static const _moduleId = 'notification_intelligence';

  Future<Map<String, bool>> _settings() async {
    final modules = await moduleRepository.getInstalled();
    final mod = modules.where((m) => m.id == _moduleId).firstOrNull;
    if (mod == null || !mod.enabled) return {};
    return mod.settings;
  }

  Future<_NotifCheck> _check(String settingKey) async {
    final s = await _settings();
    if (s.isEmpty) return _NotifCheck.moduleDisabled;
    if (s[settingKey] == false) return _NotifCheck.settingDisabled;
    final granted = await service.isAccessGranted();
    if (!granted) return _NotifCheck.permissionMissing;
    return _NotifCheck.ok;
  }

  String _errorFor(_NotifCheck check, String settingLabel) {
    switch (check) {
      case _NotifCheck.moduleDisabled:
        return 'module_disabled: Notification Intelligence module is not installed or not enabled.';
      case _NotifCheck.settingDisabled:
        return 'setting_disabled: "$settingLabel" toggle is OFF in Notification Intelligence settings.';
      case _NotifCheck.permissionMissing:
        return 'permission_missing: Notification access is not granted. Open Notification access settings to enable.';
      case _NotifCheck.ok:
        return '';
    }
  }

  /// `notification.status` — does NOT require any setting toggle, always returns
  /// the system-level grant state (used to drive UI prompts).
  Future<({bool granted, String? error})> getStatus() async {
    final modules = await moduleRepository.getInstalled();
    final mod = modules.where((m) => m.id == _moduleId).firstOrNull;
    if (mod == null || !mod.enabled) {
      return (
        granted: false,
        error: 'module_disabled: Notification Intelligence module is not installed or not enabled.',
      );
    }
    final granted = await service.isAccessGranted();
    return (granted: granted, error: null);
  }

  Future<({List<NotificationInfo>? data, String? error})> getRecent({
    int limit = 10,
  }) async {
    final check = await _check('allow_read');
    if (check != _NotifCheck.ok) {
      return (data: null, error: _errorFor(check, 'Allow Read Notifications'));
    }
    final list = await service.getRecent(limit: limit);
    return (data: list, error: null);
  }

  Future<({List<NotificationInfo>? data, String? error})> getForSummary({
    int limit = 25,
  }) async {
    final check = await _check('allow_summary');
    if (check != _NotifCheck.ok) {
      return (data: null, error: _errorFor(check, 'Allow Notification Summaries'));
    }
    final list = await service.getRecent(limit: limit);
    return (data: list, error: null);
  }

  Future<({List<NotificationInfo>? data, String? error})> getForClassify({
    int limit = 15,
  }) async {
    final check = await _check('allow_classify');
    if (check != _NotifCheck.ok) {
      return (data: null, error: _errorFor(check, 'Allow Importance Detection'));
    }
    final list = await service.getRecent(limit: limit);
    return (data: list, error: null);
  }

  Future<({NotificationInfo? data, String? error})> getForReply(
    String notificationId,
  ) async {
    final check = await _check('allow_reply_suggestion');
    if (check != _NotifCheck.ok) {
      return (data: null, error: _errorFor(check, 'Allow Reply Suggestions'));
    }
    final notif = await service.getById(notificationId);
    if (notif == null) {
      return (data: null, error: 'not_found: Notification with id "$notificationId" not in cache.');
    }
    return (data: notif, error: null);
  }

  Future<({NotificationInfo? data, String? error})> getForOpenApp(
    String notificationId,
  ) async {
    final check = await _check('allow_open_source_app');
    if (check != _NotifCheck.ok) {
      return (data: null, error: _errorFor(check, 'Allow Open Source App'));
    }
    final notif = await service.getById(notificationId);
    if (notif == null) {
      return (data: null, error: 'not_found: Notification with id "$notificationId" not in cache.');
    }
    return (data: notif, error: null);
  }

  /// Opens system Notification access settings so user can grant permission.
  Future<void> openAccessSettings() => service.openAccessSettings();
}

final notificationRepositoryProvider = Provider<NotificationRepository>(
  (ref) => NotificationRepository(
    service: ref.read(notificationServiceProvider),
    moduleRepository: ref.read(moduleRepositoryProvider),
  ),
);
