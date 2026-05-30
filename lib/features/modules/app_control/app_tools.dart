import 'package:flutter/services.dart';

import '../../../services/agent_runtime/app_alias_resolver.dart';
import '../../../services/agent_runtime/runtime_models.dart';

class AppTools {
  AppTools();

  static const _appChannel = MethodChannel('com.meowagent/app_control');

  Future<ToolExecutionResult> executeResolve(Map<String, dynamic> args) async {
    try {
      final query = (args['query'] as String? ?? args['name'] as String? ?? '')
          .trim();
      if (query.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'app.resolve',
          error: 'Empty query. Provide an app name to resolve.',
        );
      }
      final result = await AppAliasResolver.resolve(query);
      if (result == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'app.resolve',
          data: {'query': query, 'matched': false},
          error: 'No app matched query: "$query"',
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'app.resolve',
        data: {'query': query, 'matched': true, 'app': result.toJson()},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app.resolve',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeOpen(Map<String, dynamic> args) async {
    try {
      var pkg = (args['package'] as String? ?? '').trim();
      final friendlyName =
          (args['name'] as String? ?? args['query'] as String? ?? '').trim();

      if (pkg.isEmpty && friendlyName.isNotEmpty) {
        final result = await AppAliasResolver.resolve(friendlyName);
        if (result != null && result.confidence >= 0.85) {
          pkg = result.packageName;
        } else if (result != null) {
          return ToolExecutionResult(
            success: false,
            toolName: 'app.open',
            data: {'matched': result.toJson(), 'low_confidence': true},
            error:
                'Low confidence match (${result.confidence.toStringAsFixed(2)}) for "$friendlyName". Best guess: ${result.name}. Use app.resolve and ask user to confirm.',
          );
        }
      }

      if (pkg.isEmpty) {
        return ToolExecutionResult(
          success: false,
          toolName: 'app.open',
          error:
              'Could not resolve app. Call app.resolve first to get the package name.',
        );
      }

      final success =
          await _appChannel.invokeMethod<bool>('openApp', {'package': pkg}) ??
          false;
      return ToolExecutionResult(
        success: success,
        toolName: 'app.open',
        data: {'package': pkg, 'opened': success},
        error: success ? null : 'App not found or could not be launched: $pkg',
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app.open',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeListInstalled() async {
    try {
      final raw = await _appChannel.invokeMethod<List>('listInstalledApps');
      final apps =
          raw?.map((e) => Map<String, String>.from(e as Map)).toList() ?? [];
      return ToolExecutionResult(
        success: true,
        toolName: 'app.list_installed',
        data: {'apps': apps, 'count': apps.length},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app.list_installed',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeOpenSettings(
    Map<String, dynamic> args,
  ) async {
    try {
      final action = args['action'] as String? ?? 'android.settings.SETTINGS';
      await _appChannel.invokeMethod<bool>('openSettings', {'action': action});
      return ToolExecutionResult(
        success: true,
        toolName: 'settings.open',
        data: {'action': action},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'settings.open',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeOpenUrl(Map<String, dynamic> args) async {
    try {
      var url = (args['url'] as String? ?? '').trim();
      if (url.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'intent.open_url',
          error: 'Empty URL.',
        );
      }
      final lower = url.toLowerCase();
      if (!lower.startsWith('http://') &&
          !lower.startsWith('https://') &&
          !lower.contains('://')) {
        url = 'https://$url';
      }
      final success =
          await _appChannel.invokeMethod<bool>('openUrl', {'url': url}) ??
          false;
      return ToolExecutionResult(
        success: success,
        toolName: 'intent.open_url',
        data: {'url': url, 'opened': success},
        error: success ? null : 'Failed to open URL: $url',
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'intent.open_url',
        error: e.toString(),
      );
    }
  }
}
