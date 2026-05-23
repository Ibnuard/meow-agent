import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Flutter-side controller for native app control operations.
class AppControlService {
  static const _channel = MethodChannel('com.meowagent/app_control');

  /// Open an app by package name. Returns true if successful.
  Future<bool> openApp(String packageName) async {
    try {
      return await _channel.invokeMethod<bool>(
            'openApp',
            {'package': packageName},
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// List all installed launchable apps.
  Future<List<Map<String, String>>> listInstalledApps() async {
    try {
      final raw = await _channel.invokeMethod<List>('listInstalledApps');
      if (raw == null) return [];
      return raw
          .map((e) => Map<String, String>.from(e as Map))
          .toList();
    } on PlatformException {
      return [];
    }
  }

  /// Open system settings. [action] is an Android Settings action constant.
  Future<bool> openSettings({String action = 'android.settings.SETTINGS'}) async {
    try {
      return await _channel.invokeMethod<bool>(
            'openSettings',
            {'action': action},
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Open a URL in the default browser.
  Future<bool> openUrl(String url) async {
    try {
      return await _channel.invokeMethod<bool>(
            'openUrl',
            {'url': url},
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Open app info settings for a package.
  Future<bool> openAppInfo(String packageName) async {
    try {
      return await _channel.invokeMethod<bool>(
            'openAppInfo',
            {'package': packageName},
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }
}

final appControlServiceProvider = Provider<AppControlService>(
  (ref) => AppControlService(),
);
