import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../../app/theme.dart';
import '../../modules/notes/notes_repository.dart';
import '../../modules/db/user_database.dart';
import '../../modules/web/data/api_store_repository.dart';
import '../../modules/web/domain/http_executor.dart';
import '../data/miniapp_model.dart';
import '../data/miniapp_repository.dart';

class MiniAppRunnerScreen extends ConsumerStatefulWidget {
  const MiniAppRunnerScreen({super.key, required this.appId});

  final String appId;

  @override
  ConsumerState<MiniAppRunnerScreen> createState() => _MiniAppRunnerScreenState();
}

class _MiniAppRunnerScreenState extends ConsumerState<MiniAppRunnerScreen> {
  late final WebViewController _controller;
  MiniApp? _app;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        'MeowBridge',
        onMessageReceived: (message) => _handleBridgeMessage(message.message),
      );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadApp();
    });
  }

  Future<void> _loadApp() async {
    try {
      if (!mounted) return;
      final cs = context.cs;
      final extras = context.extras;
      final isDark = cs.brightness == Brightness.dark;
      final themeCss = _getThemeCss(cs, extras);

      final repo = ref.read(miniAppRepositoryProvider);
      final app = await repo.getMiniApp(widget.appId);
      if (app == null) {
        if (!mounted) return;
        setState(() {
          _error = 'Mini App with ID "${widget.appId}" not found.';
          _loading = false;
        });
        return;
      }

      final finalHtml = _injectBridge(app.codeHtml, themeCss, isDark);

      await _controller.loadHtmlString(finalHtml);

      if (!mounted) return;
      setState(() {
        _app = app;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _getThemeCss(ColorScheme cs, MeowExtras extras) {
    final primary = _colorToHex(cs.primary);
    final background = _colorToHex(cs.surface);
    final surface = _colorToHex(extras.card);
    final onPrimary = _colorToHex(cs.onPrimary);
    final onSurface = _colorToHex(cs.onSurface);
    final onSurfaceVariant = _colorToHex(cs.onSurfaceVariant);
    final error = _colorToHex(cs.error);
    final text = _colorToHex(cs.onSurface);

    return '''
      :root {
        --color-primary: $primary;
        --color-background: $background;
        --color-surface: $surface;
        --color-on-primary: $onPrimary;
        --color-on-surface: $onSurface;
        --color-on-surface-variant: $onSurfaceVariant;
        --color-error: $error;
        --color-text: $text;
      }
      body {
        background-color: transparent !important;
        color: var(--color-text) !important;
        margin: 0;
        padding: 0;
      }
    ''';
  }

  String _colorToHex(Color color) {
    return '#${color.toARGB32().toRadixString(16).substring(2, 8)}';
  }

  String _injectBridge(String originalHtml, String themeCss, bool isDark) {
    final bridgeScript = '''
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
<style>
$themeCss
* {
  -webkit-tap-highlight-color: transparent;
  -webkit-touch-callout: none;
  user-select: none;
}
input, textarea, [contenteditable="true"] {
  user-select: text;
}
::-webkit-scrollbar {
  display: none;
}
html, body {
  overscroll-behavior-y: contain;
}
</style>
<script>
(function() {
  if ($isDark) {
    document.documentElement.classList.add('dark');
  }
  window._meowCallbacks = {};
  
  window._meowResolveCallback = function(id, success, data, error) {
    const cb = window._meowCallbacks[id];
    if (cb) {
      if (success) {
        cb.resolve(data);
      } else {
        cb.reject(new Error(error));
      }
      delete window._meowCallbacks[id];
    }
  };

  function callNative(method, args) {
    return new Promise((resolve, reject) => {
      const id = Math.random().toString(36).substring(2);
      window._meowCallbacks[id] = { resolve, reject };
      
      const payload = JSON.stringify({ id, method, args });
      if (window.MeowBridge) {
        window.MeowBridge.postMessage(payload);
      } else {
        reject(new Error("MeowBridge is not available"));
      }
    });
  }

  window.meow = {
    db: {
      query: (sql, params) => callNative("db.query", { sql, params }),
      insert: (table, data) => callNative("db.insert", { table, data }),
      update: (table, data, where, whereArgs) => callNative("db.update", { table, data, where, whereArgs }),
      delete: (table, where, whereArgs) => callNative("db.delete", { table, where, whereArgs }),
      execute: (sql, params) => callNative("db.execute", { sql, params })
    },
    notes: {
      create: (title, content, tags) => callNative("notes.create", { title, content, tags }),
      list: (limit) => callNative("notes.list", { limit }),
      get: (id) => callNative("notes.get", { id })
    },
    api: {
      call: (apiId, params) => callNative("api.call", { apiId, params })
    },
    haptics: {
      vibrate: () => callNative("haptics.vibrate", {})
    },
    navigation: {
      pop: () => callNative("navigation.pop", {}),
      push: (route) => callNative("navigation.push", { route })
    },
    alert: (message) => callNative("ui.alert", { message }),
    confirm: (message) => callNative("ui.confirm", { message })
  };
})();
</script>
''';

    if (originalHtml.contains('<head>')) {
      return originalHtml.replaceFirst('<head>', '<head>$bridgeScript');
    } else if (originalHtml.contains('<html>')) {
      return originalHtml.replaceFirst('<html>', '<html><head>$bridgeScript</head>');
    } else {
      return '$bridgeScript$originalHtml';
    }
  }

  Future<void> _handleBridgeMessage(String rawMessage) async {
    try {
      final payload = jsonDecode(rawMessage) as Map<String, dynamic>;
      final callbackId = payload['id'] as String;
      final method = payload['method'] as String;
      final args = payload['args'] as Map<String, dynamic>? ?? {};

      dynamic result;
      bool success = true;
      String? errorMessage;

      try {
        switch (method) {
          case 'db.query':
            final sql = args['sql'] as String;
            final params = args['params'] as List?;
            final db = await UserDatabase.instance.database;
            result = await db.rawQuery(sql, params);
            break;

          case 'db.insert':
            final table = args['table'] as String;
            final data = args['data'] as Map<String, dynamic>;
            final db = await UserDatabase.instance.database;
            result = await db.insert(table, data);
            break;

          case 'db.update':
            final table = args['table'] as String;
            final data = args['data'] as Map<String, dynamic>;
            final where = args['where'] as String;
            final whereArgs = args['whereArgs'] as List?;
            final db = await UserDatabase.instance.database;
            result = await db.update(table, data, where: where, whereArgs: whereArgs);
            break;

          case 'db.delete':
            final table = args['table'] as String;
            final where = args['where'] as String;
            final whereArgs = args['whereArgs'] as List?;
            final db = await UserDatabase.instance.database;
            result = await db.delete(table, where: where, whereArgs: whereArgs);
            break;

          case 'db.execute':
            final sql = args['sql'] as String;
            final params = args['params'] as List?;
            final db = await UserDatabase.instance.database;
            await db.execute(sql, params);
            result = true;
            break;

          case 'notes.create':
            final title = args['title'] as String;
            final content = args['content'] as String? ?? '';
            final tags = (args['tags'] as List?)?.cast<String>() ?? [];
            final repo = NotesRepository();
            final note = await repo.createNote(
              title: title,
              content: content,
              tags: tags,
              source: 'miniapp',
            );
            result = {
              'id': note.id,
              'title': note.title,
              'createdAt': note.createdAt.millisecondsSinceEpoch,
            };
            break;

          case 'notes.list':
            final limit = (args['limit'] as num?)?.toInt() ?? 20;
            final repo = NotesRepository();
            final notes = await repo.listRecentNotes(limit: limit);
            result = notes.map((n) => {
              'id': n.id,
              'title': n.title,
              'content': n.content,
              'tags': n.tags,
              'updatedAt': n.updatedAt.millisecondsSinceEpoch,
            }).toList();
            break;

          case 'notes.get':
            final noteId = args['id'] as String;
            final repo = NotesRepository();
            final note = await repo.getNote(noteId);
            if (note != null) {
              result = {
                'id': note.id,
                'title': note.title,
                'content': note.content,
                'tags': note.tags,
                'updatedAt': note.updatedAt.millisecondsSinceEpoch,
              };
            } else {
              result = null;
            }
            break;

          case 'api.call':
            final apiId = args['apiId'] as String;
            final params = (args['params'] as Map?)?.cast<String, String>() ?? {};
            final repo = ApiStoreRepository.instance;
            final config = await repo.findById(apiId) ?? await repo.findByName(apiId);
            if (config != null) {
              final executor = HttpExecutor();
              final res = await executor.executeFromConfig(
                config: config,
                resolvedQueryParams: params,
              );
              if (res.error != null) {
                throw Exception(res.error);
              }
              result = res.body;
            } else {
              throw Exception('API not found in API Store: $apiId');
            }
            break;

          case 'haptics.vibrate':
            await HapticFeedback.lightImpact();
            result = true;
            break;

          case 'navigation.pop':
            if (mounted) {
              context.pop();
            }
            result = true;
            break;

          case 'navigation.push':
            final route = args['route'] as String;
            if (mounted) {
              context.push(route);
            }
            result = true;
            break;

          case 'ui.alert':
            final message = args['message']?.toString() ?? '';
            if (mounted) {
              await showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  content: Text(message),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            }
            result = true;
            break;

          case 'ui.confirm':
            final message = args['message']?.toString() ?? '';
            if (mounted) {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  content: Text(message),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
              result = confirmed ?? false;
            } else {
              result = false;
            }
            break;

          default:
            throw Exception('Method "$method" not supported by MeowBridge');
        }
      } catch (e) {
        success = false;
        errorMessage = e.toString();
      }

      final dataJson = jsonEncode(result);
      final errorJson = jsonEncode(errorMessage);
      final runScript = 'window._meowResolveCallback("$callbackId", $success, $dataJson, $errorJson);';
      await _controller.runJavaScript(runScript);
    } catch (e) {
      debugPrint('MeowBridge critical error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;

    if (_loading) {
      return Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: cs.brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
            statusBarBrightness: cs.brightness == Brightness.dark
                ? Brightness.dark
                : Brightness.light,
          ),
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded, color: cs.onSurface, size: 20),
            onPressed: () => context.pop(),
          ),
        ),
        body: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: cs.brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
            statusBarBrightness: cs.brightness == Brightness.dark
                ? Brightness.dark
                : Brightness.light,
          ),
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded, color: cs.onSurface, size: 20),
            onPressed: () => context.pop(),
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text(
              _error!,
              style: TextStyle(color: cs.error, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: cs.brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
          statusBarBrightness: cs.brightness == Brightness.dark
              ? Brightness.dark
              : Brightness.light,
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: cs.onSurface, size: 20),
          onPressed: () => context.pop(),
        ),
        title: Row(
          children: [
            Text(
              _app?.icon ?? '📱',
              style: const TextStyle(fontSize: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _app?.name ?? 'Mini App',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
