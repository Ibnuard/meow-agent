import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/storage/local_storage_service.dart';

class UpdateCheckResult {
  UpdateCheckResult({
    required this.isUpdateAvailable,
    required this.currentVersion,
    required this.latestVersion,
    this.releaseNotes,
    this.downloadUrl,
    this.error,
  });

  final bool isUpdateAvailable;
  final String currentVersion;
  final String latestVersion;
  final String? releaseNotes;
  final String? downloadUrl;
  final String? error;
}

class UpdateService {
  UpdateService(this._storage, {Dio? dio}) : _dio = dio ?? _defaultDio();

  final LocalStorageService _storage;
  final Dio _dio;

  static const _lastCheckMillisKey = 'update_last_check_millis';
  static const _latestVersionKey = 'update_latest_version';
  static const _downloadUrlKey = 'update_download_url';
  static const _releaseNotesKey = 'update_release_notes';

  static Dio _defaultDio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
        headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'meow-agent-app',
        },
      ),
    );
  }

  /// Checks for an update. If [force] is true, ignores the 12-hour throttle window.
  Future<UpdateCheckResult> checkForUpdate({bool force = false}) async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final lastCheckMillis = _storage.readInt(_lastCheckMillisKey) ?? 0;
      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final timeSinceLastCheck = Duration(milliseconds: nowMillis - lastCheckMillis);

      // Throttling: If not forced and last check was less than 12 hours ago, use cached results
      if (!force && timeSinceLastCheck < const Duration(hours: 12)) {
        final cachedLatest = _storage.readString(_latestVersionKey);
        if (cachedLatest != null && cachedLatest.isNotEmpty) {
          final isNewer = _isNewerVersion(currentVersion, cachedLatest);
          return UpdateCheckResult(
            isUpdateAvailable: isNewer,
            currentVersion: currentVersion,
            latestVersion: cachedLatest,
            releaseNotes: _storage.readString(_releaseNotesKey),
            downloadUrl: _storage.readString(_downloadUrlKey),
          );
        }
      }

      // Query GitHub API
      final response = await _dio.get(
        'https://api.github.com/repos/Ibnuard/meow-agent/releases/latest',
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data as Map<String, dynamic>;
        final latestVersion = (data['tag_name'] as String? ?? '').trim();
        final releaseNotes = data['body'] as String?;
        final downloadUrl = data['html_url'] as String? ?? 'https://github.com/Ibnuard/meow-agent/releases/latest';

        if (latestVersion.isEmpty) {
          return UpdateCheckResult(
            isUpdateAvailable: false,
            currentVersion: currentVersion,
            latestVersion: currentVersion,
            error: 'Empty tag name returned from GitHub.',
          );
        }

        final isNewer = _isNewerVersion(currentVersion, latestVersion);

        // Cache the results
        await _storage.writeInt(_lastCheckMillisKey, nowMillis);
        await _storage.writeString(_latestVersionKey, latestVersion);
        await _storage.writeString(_downloadUrlKey, downloadUrl);
        if (releaseNotes != null) {
          await _storage.writeString(_releaseNotesKey, releaseNotes);
        } else {
          await _storage.remove(_releaseNotesKey);
        }

        return UpdateCheckResult(
          isUpdateAvailable: isNewer,
          currentVersion: currentVersion,
          latestVersion: latestVersion,
          releaseNotes: releaseNotes,
          downloadUrl: downloadUrl,
        );
      } else {
        return UpdateCheckResult(
          isUpdateAvailable: false,
          currentVersion: currentVersion,
          latestVersion: currentVersion,
          error: 'HTTP status ${response.statusCode}',
        );
      }
    } catch (e) {
      final cachedLatest = _storage.readString(_latestVersionKey) ?? '1.0.0';
      return UpdateCheckResult(
        isUpdateAvailable: false,
        currentVersion: '1.0.0',
        latestVersion: cachedLatest,
        error: e.toString(),
      );
    }

  }

  /// SemVer comparator. Returns true if [latest] is newer than [current].
  bool _isNewerVersion(String current, String latest) {
    String clean(String v) {
      var cleaned = v.trim().toLowerCase();
      if (cleaned.startsWith('v')) {
        cleaned = cleaned.substring(1);
      }
      final dashIdx = cleaned.indexOf('-');
      if (dashIdx != -1) cleaned = cleaned.substring(0, dashIdx);
      final plusIdx = cleaned.indexOf('+');
      if (plusIdx != -1) cleaned = cleaned.substring(0, plusIdx);
      return cleaned;
    }

    final cleanCurrent = clean(current);
    final cleanLatest = clean(latest);

    final currentParts = cleanCurrent.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final latestParts = cleanLatest.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    final length = currentParts.length > latestParts.length ? currentParts.length : latestParts.length;
    for (var i = 0; i < length; i++) {
      final cur = i < currentParts.length ? currentParts[i] : 0;
      final lat = i < latestParts.length ? latestParts[i] : 0;
      if (lat > cur) return true;
      if (cur > lat) return false;
    }
    return false;
  }
}

final updateServiceProvider = Provider<UpdateService>((ref) {
  return UpdateService(ref.watch(localStorageProvider));
});
