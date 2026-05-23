import 'package:flutter/services.dart';

/// Resolves friendly app names to package names with confidence scoring.
/// Combines: built-in aliases, installed app index, and user custom aliases.
class AppAliasResolver {
  static const _channel = MethodChannel('com.meowagent/app_control');

  /// Built-in alias map: alias → list of candidate identifiers (in priority order).
  static const Map<String, List<String>> _builtinAliases = {
    // Messaging
    'wa': ['whatsapp', 'com.whatsapp', 'com.whatsapp.w4b'],
    'whatsapp': ['whatsapp', 'com.whatsapp'],
    'whatsapp business': ['com.whatsapp.w4b'],
    'wabis': ['com.whatsapp.w4b'],
    'telegram': ['telegram', 'org.telegram.messenger'],
    'tele': ['telegram', 'org.telegram.messenger'],
    'tg': ['telegram', 'org.telegram.messenger'],
    'line': ['line', 'jp.naver.line.android'],
    'signal': ['signal', 'org.thoughtcrime.securesms'],
    'discord': ['discord', 'com.discord'],
    'messenger': ['messenger', 'com.facebook.orca'],
    // Social
    'instagram': ['instagram', 'com.instagram.android'],
    'ig': ['instagram', 'com.instagram.android'],
    'twitter': ['twitter', 'com.twitter.android'],
    'x': ['twitter', 'com.twitter.android'],
    'tiktok': ['tiktok', 'com.zhiliaoapp.musically', 'com.ss.android.ugc.trill'],
    'tt': ['tiktok', 'com.zhiliaoapp.musically'],
    'facebook': ['facebook', 'com.facebook.katana'],
    'fb': ['facebook', 'com.facebook.katana'],
    'snapchat': ['snapchat', 'com.snapchat.android'],
    'snap': ['snapchat', 'com.snapchat.android'],
    'reddit': ['reddit', 'com.reddit.frontpage'],
    'linkedin': ['linkedin', 'com.linkedin.android'],
    // Google
    'youtube': ['youtube', 'com.google.android.youtube'],
    'yt': ['youtube', 'com.google.android.youtube'],
    'maps': ['google maps', 'maps', 'com.google.android.apps.maps'],
    'gmaps': ['google maps', 'com.google.android.apps.maps'],
    'google maps': ['com.google.android.apps.maps'],
    'gmail': ['gmail', 'com.google.android.gm'],
    'chrome': ['chrome', 'com.android.chrome'],
    'drive': ['drive', 'com.google.android.apps.docs'],
    'meet': ['meet', 'com.google.android.apps.tachyon'],
    'photos': ['photos', 'com.google.android.apps.photos'],
    'play': ['play store', 'com.android.vending'],
    'playstore': ['play store', 'com.android.vending'],
    'play store': ['com.android.vending'],
    'youtube music': ['com.google.android.apps.youtube.music'],
    'ytmusic': ['com.google.android.apps.youtube.music'],
    // Indonesian
    'gojek': ['gojek', 'com.gojek.app'],
    'grab': ['grab', 'com.grabtaxi.passenger'],
    'tokopedia': ['tokopedia', 'com.tokopedia.tkpd'],
    'toko ijo': ['tokopedia', 'com.tokopedia.tkpd'],
    'shopee': ['shopee', 'com.shopee.id'],
    'lazada': ['lazada', 'com.lazada.android'],
    'dana': ['dana', 'id.dana'],
    'ovo': ['ovo', 'ovo.id'],
    'gopay': ['gopay', 'com.gojek.gopay'],
    'jenius': ['com.btpn.dc'],
    'mybca': ['com.bca.mybca.omni'],
    'livin': ['id.co.bankmandiri.livin'],
    'brimo': ['id.co.bri.brimo'],
    // Productivity
    'spotify': ['spotify', 'com.spotify.music'],
    'netflix': ['netflix', 'com.netflix.mediaclient'],
    'zoom': ['zoom', 'us.zoom.videomeetings'],
    'notion': ['notion', 'notion.id'],
    'slack': ['slack', 'com.Slack'],
    'github': ['github', 'com.github.android'],
    'vscode': ['code', 'com.microsoft.vscode'],
    // System
    'camera': ['camera', 'com.android.camera2', 'com.google.android.GoogleCamera'],
    'gallery': ['photos', 'com.google.android.apps.photos'],
    'calculator': ['calculator', 'com.google.android.calculator'],
    'calendar': ['calendar', 'com.google.android.calendar'],
    'clock': ['clock', 'com.google.android.deskclock'],
    'contacts': ['contacts', 'com.google.android.contacts'],
    'phone': ['phone', 'com.google.android.dialer'],
    'files': ['files', 'com.google.android.documentsui'],
  };

  /// Resolve a query to an app match with confidence score.
  /// Returns null if no match found.
  static Future<AppResolveResult?> resolve(String query) async {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return null;

    // Get installed apps once.
    final installed = await _listInstalledApps();
    if (installed.isEmpty) return null;

    final matches = <_ScoredMatch>[];

    // 1. Exact alias match (confidence 0.95).
    if (_builtinAliases.containsKey(q)) {
      final candidates = _builtinAliases[q]!;
      for (final candidate in candidates) {
        final pkg = _findPackage(installed, candidate);
        if (pkg != null) {
          matches.add(_ScoredMatch(pkg, 0.95));
        }
      }
    }

    // 2. Exact package name match (confidence 0.92).
    final exactPkg = installed.firstWhere(
      (a) => (a['package'] ?? '').toLowerCase() == q,
      orElse: () => {},
    );
    if (exactPkg.isNotEmpty) {
      matches.add(_ScoredMatch(exactPkg, 0.92));
    }

    // 3. Exact name match (confidence 0.90).
    final exactName = installed.firstWhere(
      (a) => (a['name'] ?? '').toLowerCase() == q,
      orElse: () => {},
    );
    if (exactName.isNotEmpty) {
      matches.add(_ScoredMatch(exactName, 0.90));
    }

    // 4. App name contains query (confidence based on match quality).
    for (final app in installed) {
      final name = (app['name'] ?? '').toLowerCase();
      if (name.contains(q) && name != q) {
        final score = q.length / name.length * 0.85;
        matches.add(_ScoredMatch(app, score.clamp(0.4, 0.85)));
      }
    }

    // 5. Package contains query (confidence 0.50).
    for (final app in installed) {
      final pkg = (app['package'] ?? '').toLowerCase();
      if (pkg.contains(q)) {
        matches.add(_ScoredMatch(app, 0.50));
      }
    }

    if (matches.isEmpty) return null;

    // Deduplicate by package, keep highest score.
    final byPackage = <String, _ScoredMatch>{};
    for (final m in matches) {
      final pkg = m.app['package'] ?? '';
      if (pkg.isEmpty) continue;
      if (!byPackage.containsKey(pkg) ||
          byPackage[pkg]!.confidence < m.confidence) {
        byPackage[pkg] = m;
      }
    }

    final sorted = byPackage.values.toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));

    final best = sorted.first;
    final alternatives = sorted.skip(1).take(3).toList();

    return AppResolveResult(
      name: best.app['name'] ?? '',
      packageName: best.app['package'] ?? '',
      confidence: best.confidence,
      alternatives: alternatives
          .map((m) => AppResolveCandidate(
                name: m.app['name'] ?? '',
                packageName: m.app['package'] ?? '',
                confidence: m.confidence,
              ))
          .toList(),
    );
  }

  static Map<String, String>? _findPackage(
    List<Map<String, String>> installed,
    String candidate,
  ) {
    final c = candidate.toLowerCase();
    // Try exact package match first.
    final pkgMatch = installed.firstWhere(
      (a) => (a['package'] ?? '').toLowerCase() == c,
      orElse: () => {},
    );
    if (pkgMatch.isNotEmpty) return pkgMatch;
    // Then try exact name match.
    final nameMatch = installed.firstWhere(
      (a) => (a['name'] ?? '').toLowerCase() == c,
      orElse: () => {},
    );
    if (nameMatch.isNotEmpty) return nameMatch;
    return null;
  }

  static Future<List<Map<String, String>>> _listInstalledApps() async {
    try {
      final raw = await _channel.invokeMethod<List>('listInstalledApps');
      return raw?.map((e) => Map<String, String>.from(e as Map)).toList() ?? [];
    } catch (_) {
      return [];
    }
  }
}

class _ScoredMatch {
  _ScoredMatch(this.app, this.confidence);
  final Map<String, String> app;
  final double confidence;
}

/// Result of an app resolution.
class AppResolveResult {
  AppResolveResult({
    required this.name,
    required this.packageName,
    required this.confidence,
    this.alternatives = const [],
  });

  final String name;
  final String packageName;
  final double confidence;
  final List<AppResolveCandidate> alternatives;

  Map<String, dynamic> toJson() => {
        'name': name,
        'packageName': packageName,
        'confidence': confidence,
        'alternatives': alternatives.map((a) => a.toJson()).toList(),
      };
}

class AppResolveCandidate {
  AppResolveCandidate({
    required this.name,
    required this.packageName,
    required this.confidence,
  });

  final String name;
  final String packageName;
  final double confidence;

  Map<String, dynamic> toJson() => {
        'name': name,
        'packageName': packageName,
        'confidence': confidence,
      };
}
