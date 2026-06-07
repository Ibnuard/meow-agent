import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../settings/data/app_language_provider.dart';
import 'vm_models.dart';
import 'vm_plugins.dart';
import 'vm_repository.dart';
import 'vm_runtime_service.dart';
import 'vm_terminal_screen.dart';

/// VM Runtime control surface.
///
/// Per AGENTS.md (#3 Soft Futuristic, calm interaction):
/// 1. Status panel + one primary action driven by current runtime state.
/// 2. Plugin grid: tap to install language toolchains. Disabled until the
///    runtime is running.
/// 3. The user does not see URL/checksum/version inputs — handled by
///    [VmRootfsPreset].
class VmRuntimeScreen extends ConsumerStatefulWidget {
  const VmRuntimeScreen({super.key});

  @override
  ConsumerState<VmRuntimeScreen> createState() => _VmRuntimeScreenState();
}

class _VmRuntimeScreenState extends ConsumerState<VmRuntimeScreen> {
  bool _busy = false;
  final _installingPlugins = <String>{};
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkStatus());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// While a long op (download / plugin install) is in flight, poll the
  /// native side every ~1.2s so the UI shows live progress messages.
  /// VmRuntimeManager updates a volatile `lastMessage` each chunk; we just
  /// surface it through the existing snapshot path.
  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) async {
      if (!mounted || (!_busy && _installingPlugins.isEmpty)) {
        _pollTimer?.cancel();
        return;
      }
      final snapshot = await ref.read(vmRuntimeServiceProvider).status();
      await ref.read(vmRuntimeRepositoryProvider).saveSnapshot(snapshot);
      ref.invalidate(vmRuntimeSnapshotProvider);
    });
  }

  Future<void> _runRuntime(
    Future<VmRuntimeSnapshot> Function() action,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    _startPolling();
    final snapshot = await action();
    _pollTimer?.cancel();
    await ref.read(vmRuntimeRepositoryProvider).saveSnapshot(snapshot);
    ref.invalidate(vmRuntimeSnapshotProvider);
    final s = AppStrings(resolveLanguageCode(ref.read(appLanguageProvider)));
    final message = _statusMessage(snapshot, s);
    if (mounted && message.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _checkStatus() =>
      _runRuntime(() => ref.read(vmRuntimeServiceProvider).status());

  Future<void> _install() {
    const preset = VmRootfsPreset.defaultPreset;
    return _runRuntime(
      () => ref
          .read(vmRuntimeServiceProvider)
          .downloadRootfs(
            url: preset.url,
            sha256: preset.sha256,
            version: preset.version,
          ),
    );
  }

  Future<void> _startService() =>
      _runRuntime(() => ref.read(vmRuntimeServiceProvider).start());

  Future<void> _stopService() =>
      _runRuntime(() => ref.read(vmRuntimeServiceProvider).stop());

  void _openTerminal() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const VmTerminalScreen()),
    );
  }

  Future<void> _installPlugin(VmPlugin plugin) async {
    final s = AppStrings(resolveLanguageCode(ref.read(appLanguageProvider)));
    final confirmed = await showMeowConfirmDialog(
      context,
      isId: s.isId,
      title: s.vmPluginConfirmTitle(plugin.name),
      message: s.vmPluginConfirmBody(plugin.name, plugin.estimatedSizeMb),
      confirmLabel: s.vmPluginInstall,
      cancelLabel: s.cancel,
    );
    if (!confirmed || !mounted) return;

    setState(() => _installingPlugins.add(plugin.id));
    final repo = ref.read(vmRuntimeRepositoryProvider);
    await repo.savePluginState(
      VmPluginState(
        pluginId: plugin.id,
        status: VmPluginStatus.installing,
      ),
    );
    ref.invalidate(vmPluginStatesProvider);

    final result = await ref
        .read(vmRuntimeServiceProvider)
        .installPlugin(
          pluginId: plugin.id,
          installCommand: plugin.installCommand,
        );

    // After install, probe to capture version output.
    var version = '';
    if (result.success) {
      final probe = await ref
          .read(vmRuntimeServiceProvider)
          .probePlugin(
            pluginId: plugin.id,
            versionCommand: plugin.versionCommand,
          );
      if (probe.success) {
        version = probe.stdout.trim();
      }
    }

    await repo.savePluginState(
      VmPluginState(
        pluginId: plugin.id,
        status: result.success
            ? VmPluginStatus.installed
            : VmPluginStatus.error,
        version: version,
        message: result.success ? '' : (result.message.isNotEmpty
            ? result.message
            : (result.stderr.isNotEmpty ? result.stderr : '')),
      ),
    );
    ref.invalidate(vmPluginStatesProvider);

    if (!mounted) return;
    setState(() => _installingPlugins.remove(plugin.id));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.success
              ? s.vmPluginInstallSuccess(plugin.name)
              : s.vmPluginInstallFailed(plugin.name),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));
    final snapshotAsync = ref.watch(vmRuntimeSnapshotProvider);
    final snapshot =
        snapshotAsync.valueOrNull ??
        VmRuntimeSnapshot.unavailable(message: s.vmNativeUnavailable);
    final canManagePlugins =
        snapshot.nativeRuntimeAvailable &&
        snapshot.status == VmRuntimeStatus.running;

    return Scaffold(
      backgroundColor: isDark ? cs.surface : const Color(0xFFFBFCFE),
      appBar: AppBar(title: Text(s.vmRuntimeTitle)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          24 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          MeowCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: extras.subtleBorder),
                      ),
                      child: Icon(
                        Icons.terminal_rounded,
                        color: cs.primary,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.vmRuntimeTitle,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            s.vmRuntimeSubtitle,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.35,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _StatusPanel(snapshot: snapshot, s: s),
              ],
            ),
          ),
          const SizedBox(height: 20),
          ..._buildActionButtons(snapshot, s),
          const SizedBox(height: 28),
          _PluginSection(
            s: s,
            canInstall: canManagePlugins,
            installingIds: _installingPlugins,
            onInstall: _installPlugin,
          ),
        ],
      ),
    );
  }

  /// Status-driven primary action set.
  List<Widget> _buildActionButtons(VmRuntimeSnapshot snapshot, AppStrings s) {
    if (!snapshot.nativeRuntimeAvailable) {
      return [
        MeowSecondaryButton(
          label: s.checkStatus,
          icon: Icons.refresh_rounded,
          loading: _busy,
          onPressed: _busy ? null : _checkStatus,
        ),
      ];
    }

    switch (snapshot.status) {
      case VmRuntimeStatus.notInstalled:
      case VmRuntimeStatus.error:
        return [
          MeowPrimaryButton(
            label: s.vmInstallRuntime,
            icon: Icons.download_rounded,
            loading: _busy,
            onPressed: _busy ? null : _install,
          ),
        ];
      case VmRuntimeStatus.downloading:
      case VmRuntimeStatus.starting:
        return [
          MeowPrimaryButton(
            label: snapshot.status == VmRuntimeStatus.downloading
                ? s.vmRuntimeDownloading
                : s.vmRuntimeStarting,
            icon: Icons.hourglass_top_rounded,
            loading: true,
            onPressed: null,
          ),
        ];
      case VmRuntimeStatus.installed:
      case VmRuntimeStatus.stopped:
        return [
          MeowPrimaryButton(
            label: s.vmStartRuntime,
            icon: Icons.play_arrow_rounded,
            loading: _busy,
            onPressed: _busy ? null : _startService,
          ),
          const SizedBox(height: 12),
          MeowSecondaryButton(
            label: s.vmReinstallRuntime,
            icon: Icons.refresh_rounded,
            loading: _busy,
            onPressed: _busy ? null : _install,
          ),
        ];
      case VmRuntimeStatus.running:
        return [
          MeowPrimaryButton(
            label: s.vmOpenTerminal,
            icon: Icons.terminal_rounded,
            loading: _busy,
            onPressed: _busy ? null : _openTerminal,
          ),
          const SizedBox(height: 12),
          MeowSecondaryButton(
            label: s.vmStopRuntime,
            icon: Icons.stop_rounded,
            loading: _busy,
            danger: true,
            onPressed: _busy ? null : _stopService,
          ),
          const SizedBox(height: 12),
          MeowSecondaryButton(
            label: s.checkStatus,
            icon: Icons.refresh_rounded,
            loading: _busy,
            onPressed: _busy ? null : _checkStatus,
          ),
        ];
      case VmRuntimeStatus.unavailable:
        return [
          MeowSecondaryButton(
            label: s.checkStatus,
            icon: Icons.refresh_rounded,
            loading: _busy,
            onPressed: _busy ? null : _checkStatus,
          ),
        ];
    }
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.snapshot, required this.s});

  final VmRuntimeSnapshot snapshot;
  final AppStrings s;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final color = !snapshot.nativeRuntimeAvailable
        ? Colors.amber
        : switch (snapshot.status) {
            VmRuntimeStatus.running => Colors.green,
            VmRuntimeStatus.error => cs.error,
            _ => cs.primary,
          };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_statusIcon(snapshot), size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _statusLabel(snapshot.status, s),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _statusMessage(snapshot, s),
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: cs.onSurfaceVariant,
            ),
          ),
          if (snapshot.port != null) ...[
            const SizedBox(height: 8),
            Text(
              s.vmPreviewPort(snapshot.port!),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _statusIcon(VmRuntimeSnapshot snapshot) {
    if (!snapshot.nativeRuntimeAvailable) return Icons.warning_amber_rounded;
    return switch (snapshot.status) {
      VmRuntimeStatus.running => Icons.check_circle_rounded,
      VmRuntimeStatus.error => Icons.error_outline_rounded,
      VmRuntimeStatus.downloading ||
      VmRuntimeStatus.starting => Icons.hourglass_top_rounded,
      _ => Icons.info_outline_rounded,
    };
  }

  String _statusLabel(VmRuntimeStatus status, AppStrings s) => switch (status) {
    VmRuntimeStatus.notInstalled => s.vmStatusNotInstalled,
    VmRuntimeStatus.downloading => s.vmStatusDownloading,
    VmRuntimeStatus.installed => s.vmStatusInstalled,
    VmRuntimeStatus.starting => s.vmStatusStarting,
    VmRuntimeStatus.running => s.vmStatusRunning,
    VmRuntimeStatus.stopped => s.vmStatusStopped,
    VmRuntimeStatus.error => s.vmStatusError,
    VmRuntimeStatus.unavailable => s.vmStatusUnavailable,
  };
}

class _PluginSection extends ConsumerWidget {
  const _PluginSection({
    required this.s,
    required this.canInstall,
    required this.installingIds,
    required this.onInstall,
  });

  final AppStrings s;
  final bool canInstall;
  final Set<String> installingIds;
  final void Function(VmPlugin plugin) onInstall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final statesAsync = ref.watch(vmPluginStatesProvider);
    final states = statesAsync.valueOrNull ?? const <String, VmPluginState>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.vmPluginsTitle,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                s.vmPluginsSubtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
              if (!canInstall) ...[
                const SizedBox(height: 8),
                Text(
                  s.vmPluginRunRequired,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.amber.shade700,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        for (final plugin in VmPluginCatalog.available) ...[
          _PluginRow(
            plugin: plugin,
            state: states[plugin.id],
            isInstalling: installingIds.contains(plugin.id),
            canInstall: canInstall,
            onInstall: () => onInstall(plugin),
            s: s,
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _PluginRow extends StatelessWidget {
  const _PluginRow({
    required this.plugin,
    required this.state,
    required this.isInstalling,
    required this.canInstall,
    required this.onInstall,
    required this.s,
  });

  final VmPlugin plugin;
  final VmPluginState? state;
  final bool isInstalling;
  final bool canInstall;
  final VoidCallback onInstall;
  final AppStrings s;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final installed = state?.status == VmPluginStatus.installed;
    final installButtonEnabled = canInstall && !isInstalling && !installed;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? extras.card : const Color(0xFFF4F7FB),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? extras.subtleBorder : const Color(0xFFEAF0F8),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: plugin.accent.withValues(alpha: isDark ? 0.18 : 0.12),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: extras.subtleBorder),
            ),
            alignment: Alignment.center,
            child: Icon(plugin.icon, color: plugin.accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        plugin.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: cs.onSurface,
                          height: 1.1,
                        ),
                      ),
                    ),
                    if (installed && state!.version.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          state!.version,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  plugin.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '~${plugin.estimatedSizeMb} MB',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _PluginActionButton(
            installed: installed,
            isInstalling: isInstalling,
            enabled: installButtonEnabled,
            onPressed: installButtonEnabled ? onInstall : null,
            s: s,
          ),
        ],
      ),
    );
  }
}

class _PluginActionButton extends StatelessWidget {
  const _PluginActionButton({
    required this.installed,
    required this.isInstalling,
    required this.enabled,
    required this.onPressed,
    required this.s,
  });

  final bool installed;
  final bool isInstalling;
  final bool enabled;
  final VoidCallback? onPressed;
  final AppStrings s;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    if (installed) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_rounded,
              size: 14,
              color: Colors.green.shade600,
            ),
            const SizedBox(width: 5),
            Text(
              s.vmPluginInstalled,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.green.shade700,
              ),
            ),
          ],
        ),
      );
    }
    if (isInstalling) {
      return SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2.4, color: cs.primary),
      );
    }
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        backgroundColor: enabled
            ? cs.primary.withValues(alpha: 0.1)
            : cs.onSurface.withValues(alpha: 0.04),
        foregroundColor: enabled ? cs.primary : cs.onSurfaceVariant,
      ),
      child: Text(
        s.vmPluginInstall,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Free function so the screen can also reuse it for SnackBar text.
String _statusMessage(VmRuntimeSnapshot snapshot, AppStrings s) {
  if (!snapshot.nativeRuntimeAvailable) return s.vmNativeUnavailable;
  if (snapshot.message.isNotEmpty) return snapshot.message;
  return switch (snapshot.status) {
    VmRuntimeStatus.notInstalled => s.vmRuntimeNeedInstall,
    VmRuntimeStatus.installed ||
    VmRuntimeStatus.stopped => s.vmRuntimeIdle,
    VmRuntimeStatus.running => s.vmRuntimeReady,
    VmRuntimeStatus.downloading => s.vmRuntimeDownloading,
    VmRuntimeStatus.starting => s.vmRuntimeStarting,
    _ => s.vmStatusReady,
  };
}
