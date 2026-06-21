import 'dart:io';

/// Loads MEOW_TEST_* credentials from the project-root .env file.
///
/// Skips comments (#) and blank lines. Returns empty strings for missing keys.
class EnvLoader {
  const EnvLoader._();

  static String? _cachedBaseUrl;
  static String? _cachedApiKey;
  static String? _cachedModel;

  static String get baseUrl => _cachedBaseUrl ?? '';
  static String get apiKey => _cachedApiKey ?? '';
  static String get model => _cachedModel ?? '';
  static bool get isAvailable => baseUrl.isNotEmpty && apiKey.isNotEmpty;

  /// (Re-)read .env from disk. Call once in setUpAll.
  static void load({String? projectRoot}) {
    // Resolve from explicit path, then current directory, then walk up.
    File? envFile;
    final candidates = <String>[
      if (projectRoot != null) '${projectRoot.replaceAll('\\', '/')}/.env',
      '${Directory.current.path.replaceAll('\\', '/')}/.env',
    ];

    for (final path in candidates) {
      final f = File(path);
      if (f.existsSync()) {
        envFile = f;
        break;
      }
    }

    // Walk up from current directory as last resort.
    if (envFile == null) {
      var dir = Directory.current;
      while (true) {
        final candidate = File('${dir.path}/.env');
        if (candidate.existsSync()) {
          envFile = candidate;
          break;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }

    if (envFile == null) {
      _cachedBaseUrl = '';
      _cachedApiKey = '';
      _cachedModel = '';
      return;
    }

    final lines = envFile.readAsLinesSync();
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final eq = trimmed.indexOf('=');
      if (eq == -1) continue;
      final key = trimmed.substring(0, eq).trim();
      final value = trimmed.substring(eq + 1).trim();
      switch (key) {
        case 'MEOW_TEST_BASE_URL':
          _cachedBaseUrl = value;
        case 'MEOW_TEST_API_KEY':
          _cachedApiKey = value;
        case 'MEOW_TEST_MODEL':
          _cachedModel = value;
      }
    }
  }
}