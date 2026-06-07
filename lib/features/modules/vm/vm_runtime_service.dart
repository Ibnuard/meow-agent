import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'vm_models.dart';

/// Method-channel bridge to the native proot runtime.
///
/// Until the Kotlin side ships a real proot binary in `jniLibs/`, every call
/// returns an `unavailable` snapshot — never a fake "success". Per AGENTS.md
/// #1 and #6, we never claim success we cannot verify.
class VmRuntimeService {
  const VmRuntimeService();

  static const _channel = MethodChannel('com.meowagent/vm_runtime');

  Future<VmRuntimeSnapshot> status() => _invokeSnapshot('status');

  Future<VmRuntimeSnapshot> downloadRootfs({
    required String url,
    required String sha256,
    required String version,
  }) => _invokeSnapshot('downloadRootfs', {
    'url': url,
    'sha256': sha256,
    'version': version,
  });

  Future<VmRuntimeSnapshot> start() => _invokeSnapshot('start');

  Future<VmRuntimeSnapshot> stop() => _invokeSnapshot('stop');

  Future<VmCommandResult> runCommand(String command, {int timeoutMs = 60000}) {
    return _invokeCommand('runCommand', {
      'command': command,
      'timeout_ms': timeoutMs,
    });
  }

  /// Install a plugin by running its [installCommand] inside the runtime.
  /// The native side streams progress to a notification; we just await the
  /// final result.
  Future<VmCommandResult> installPlugin({
    required String pluginId,
    required String installCommand,
    int timeoutMs = 600000, // 10 minutes for big toolchains.
  }) {
    return _invokeCommand('installPlugin', {
      'plugin_id': pluginId,
      'install_command': installCommand,
      'timeout_ms': timeoutMs,
    });
  }

  /// Probe a plugin's version command and return the stdout if installed.
  Future<VmCommandResult> probePlugin({
    required String pluginId,
    required String versionCommand,
  }) {
    return _invokeCommand('probePlugin', {
      'plugin_id': pluginId,
      'version_command': versionCommand,
      'timeout_ms': 5000,
    });
  }

  Future<VmRuntimeSnapshot> _invokeSnapshot(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(method, args);
      if (raw == null) {
        return VmRuntimeSnapshot.unavailable(
          message: 'VM runtime returned no status data.',
        );
      }
      return VmRuntimeSnapshot.fromJson(raw);
    } on MissingPluginException {
      return VmRuntimeSnapshot.unavailable(
        message: 'Native VM runtime is not connected yet.',
      );
    } on PlatformException catch (e) {
      return VmRuntimeSnapshot.unavailable(
        message: e.message ?? 'VM runtime request failed.',
      );
    }
  }

  Future<VmCommandResult> _invokeCommand(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(method, args);
      if (raw == null) {
        return VmCommandResult.unavailable(
          'VM runtime returned no result for $method.',
        );
      }
      return VmCommandResult.fromJson(raw);
    } on MissingPluginException {
      return VmCommandResult.unavailable(
        'Native VM runtime is not connected yet.',
      );
    } on PlatformException catch (e) {
      return VmCommandResult.unavailable(
        e.message ?? 'VM runtime request failed.',
      );
    }
  }
}

final vmRuntimeServiceProvider = Provider<VmRuntimeService>((ref) {
  return const VmRuntimeService();
});
