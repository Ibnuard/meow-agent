import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../../services/permission/permission_manager.dart';
import '../../agents/data/agent_repository.dart';
import '../../settings/data/app_language_provider.dart';
import '../calendar/calendar_screen.dart';
import '../db/presentation/db_manager_screen.dart';
import '../data/clipboard_service_controller.dart';
import '../data/module_model.dart';
import '../data/module_repository.dart';
import '../vm/vm_runtime_screen.dart';
import '../web/presentation/api_store_screen.dart';
import '../workflows/workflow_list_screen.dart';
import 'module_visuals.dart';
import 'mixins/device_context_handler.dart';
import 'mixins/communication_handler.dart';
import 'mixins/notification_intelligence_handler.dart';
import 'mixins/permission_gated_toggle_handler.dart';

/// Detail screen for an installed module with toggle settings.
class ModuleDetailScreen extends ConsumerStatefulWidget {
  const ModuleDetailScreen({super.key, required this.moduleId});

  final String moduleId;

  @override
  ConsumerState<ModuleDetailScreen> createState() => _ModuleDetailScreenState();
}

class _ModuleDetailScreenState extends ConsumerState<ModuleDetailScreen>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        DeviceContextHandlerMixin,
        CommunicationHandlerMixin,
        NotificationIntelligenceHandlerMixin,
        PermissionGatedToggleHandlerMixin {
  ModuleModel? _module;
  bool _moduleLoaded = false;
  bool _installingMissingModule = false;
  AnimationController? _promptBorderController;
  bool _promptBorderBoosted = false;
  // Manual offset added when the user taps "Shuffle" on the Today Prompt card.
  // The base index rotates deterministically every 6 hours; shuffle just nudges
  // it forward within the current module's prompt list.
  int _promptShuffleOffset = 0;

  @override
  ModuleModel? get module => _module;

  @override
  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }

  @override
  PermissionManager get permissionManager =>
      ref.read(permissionManagerProvider);

  void onModuleUpdated(ModuleModel updated) {
    if (mounted) {
      setState(() => _module = updated);
    }
  }

  @override
  void initState() {
    super.initState();
    _ensurePromptBorderController();
    WidgetsBinding.instance.addObserver(this);
    _loadModule();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _promptBorderController?.dispose();
    super.dispose();
  }

  AnimationController _ensurePromptBorderController() {
    return _promptBorderController ??= (AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat());
  }

  void _setPromptBorderBoosted(bool boosted) {
    if (!mounted || _promptBorderBoosted == boosted) return;
    final controller = _ensurePromptBorderController();
    final value = controller.value;
    controller
      ..stop()
      ..duration = boosted
          ? const Duration(milliseconds: 3600)
          : const Duration(seconds: 10)
      ..value = value
      ..repeat();
    setState(() => _promptBorderBoosted = boosted);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check permissions when user returns from settings.
    if (state == AppLifecycleState.resumed) {
      _loadModule();
    }
  }

  Future<void> _loadModule() async {
    final modules = await ref.read(moduleRepositoryProvider).getInstalled();
    final found = modules.where((m) => m.id == widget.moduleId).firstOrNull;
    if (!mounted) return;
    setState(() {
      _module = found;
      _moduleLoaded = true;
    });
    if (found != null) {
      await _syncLoadedModuleState();
    }
  }

  Future<void> _syncLoadedModuleState() async {
    _syncCommunicationState();
  }

  ModuleModel? _availableModuleSpec() {
    return ModuleRegistry.available
        .where((m) => m.id == widget.moduleId)
        .firstOrNull;
  }

  Future<void> _installMissingModule(ModuleModel spec) async {
    if (_installingMissingModule) return;
    setState(() => _installingMissingModule = true);
    try {
      await ref.read(moduleRepositoryProvider).install(spec);
      ref.invalidate(installedModulesProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.moduleInstalled(spec.name)),
          duration: const Duration(seconds: 2),
        ),
      );
      await _loadModule();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s.failedLoadModules)));
    } finally {
      if (mounted) {
        setState(() => _installingMissingModule = false);
      }
    }
  }

  /// Sync communication module state when returning from settings.
  Future<void> _syncCommunicationState() async {
    if (_module == null || _module!.id != 'communication') return;
    // No WA/Telegram state to sync anymore — call/sms/contacts
    // permissions are handled inline on toggle.
  }

  Future<void> _toggleSetting(String key, bool value) async {
    if (_module == null) return;

    final permitted = await handlePermissionGatedToggle(key, value);
    if (!permitted) return;

    await handleDeviceContextToggle(key, value);
    await handleCommunicationToggle(key, value);
    final shouldContinueNotification =
        await handleNotificationIntelligenceToggle(key, value);
    if (!shouldContinueNotification) return;

    final updated = _module!.copyWith(
      settings: {..._module!.settings, key: value},
    );
    await ref.read(moduleRepositoryProvider).update(updated);
    ref.invalidate(installedModulesProvider);
    setState(() => _module = updated);
  }

  Future<void> _toggleEnabled(bool value) async {
    if (_module == null) return;

    // Workflow module requires SCHEDULE_EXACT_ALARM permission on Android 14+.
    if (value && _module!.id == 'workflows') {
      final granted = await _checkAlarmPermission();
      if (!granted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(s.alarmsPermissionRequired),
            action: SnackBarAction(
              label: s.openLabel,
              onPressed: _openAlarmSettings,
            ),
          ),
        );
        return;
      }
    }

    final updated = _module!.copyWith(enabled: value);
    await ref.read(moduleRepositoryProvider).update(updated);
    ref.invalidate(installedModulesProvider);
    setState(() => _module = updated);
  }

  /// Check if SCHEDULE_EXACT_ALARM permission is granted.
  Future<bool> _checkAlarmPermission() async {
    final result = await permissionManager.check(
      PermissionType.scheduleExactAlarm,
    );
    return result == PermissionResult.granted;
  }

  /// Open system alarm permission settings.
  Future<void> _openAlarmSettings() async {
    await permissionManager.openAlarmSettings();
  }

  Future<void> _uninstall() async {
    if (_module?.id == 'notification_intelligence') {
      await ref
          .read(clipboardServiceControllerProvider)
          .stopNotificationService();
    }

    if (!mounted) return;
    final confirmed = await showMeowConfirmDialog(
      context,
      strings: s,
      title: s.uninstallModule,
      message: s.moduleUninstallDialog(_module?.name ?? 'modul ini'),
      confirmLabel: s.uninstall,
      cancelLabel: s.cancel,
    );
    if (confirmed && mounted) {
      await ref.read(moduleRepositoryProvider).uninstall(widget.moduleId);
      ref.invalidate(installedModulesProvider);
      if (mounted) context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_module == null) {
      if (!_moduleLoaded) {
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      return _buildMissingModuleScreen(cs: cs, isDark: isDark);
    }

    final module = _module!;
    final languagePref = ref.watch(appLanguageProvider);
    final langCode = resolveLanguageCode(languagePref);
    final s = AppStrings(langCode);
    final settingLabels = _settingLabels(module.id, strings: s);
    final visibleSettingEntries = module.settings.entries
        .where((entry) => _settingVisible(module, entry))
        .toList(growable: false);

    return Scaffold(
      backgroundColor: isDark ? cs.surface : const Color(0xFFFBFCFE),
      appBar: AppBar(
        title: Text(module.name),
        actions: [
          IconButton(
            icon: Icon(Icons.delete_outline_rounded, color: cs.error),
            tooltip: s.uninstallTooltip,
            onPressed: _uninstall,
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(context).padding.bottom + 24,
        ),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: isDark ? extras.card : const Color(0xFFF4F7FB),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark ? extras.subtleBorder : const Color(0xFFEAF0F8),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ModuleIconBadge(
                  moduleId: module.id,
                  size: 58,
                  iconSize: 27,
                  radius: 20,
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        module.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: cs.onSurface,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        _moduleDescription(module, strings: s),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: extras.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: extras.subtleBorder),
            ),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                s.moduleEnabled,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              subtitle: Text(
                s.moduleEnabledDesc,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              value: module.enabled,
              activeTrackColor: cs.primary.withValues(alpha: 0.82),
              activeThumbColor: Colors.white,
              inactiveTrackColor: cs.onSurfaceVariant.withValues(alpha: 0.22),
              inactiveThumbColor: cs.onSurfaceVariant.withValues(alpha: 0.72),
              onChanged: _toggleEnabled,
            ),
          ),

          const SizedBox(height: 20),

          _buildTodayPromptCard(module: module, cs: cs, extras: extras),

          const SizedBox(height: 20),

          // Notes module: show "Open Notes" button when enabled.
          if (module.id == 'notes' && module.enabled) ...[
            GestureDetector(
              onTap: () => context.push('/notes'),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.note_outlined, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      s.openNotes,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Calendar module: show "Open Calendar" button when enabled.
          if (module.id == 'calendar' && module.enabled) ...[
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CalendarScreen()),
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.calendar_month_rounded,
                      size: 18,
                      color: cs.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      s.openCalendar,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Workflows module: show "Open Workflows" button when enabled.
          if (module.id == 'workflows' && module.enabled) ...[
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const WorkflowListScreen()),
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.schedule_rounded, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      s.openWorkflows,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Web/API module: show "Open API Store" button when enabled.
          if (module.id == 'web' && module.enabled) ...[
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ApiStoreScreen()),
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.cloud_rounded, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      s.openApiStore,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Database module: show "Open Database Manager" button when enabled.
          if (module.id == 'database' && module.enabled) ...[
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DbManagerScreen()),
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.storage_rounded, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      s.openDatabaseManager,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // VM Runtime module: show "Open VM Runtime" button when enabled.
          if (module.id == 'vm' && module.enabled) ...[
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const VmRuntimeScreen()),
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.terminal_rounded, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      s.openVmRuntime,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          if (module.enabled && visibleSettingEntries.isNotEmpty) ...[
            _buildSettingsSection(
              module: module,
              entries: visibleSettingEntries,
              settingLabels: settingLabels,
              cs: cs,
              extras: extras,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMissingModuleScreen({
    required ColorScheme cs,
    required bool isDark,
  }) {
    final spec = _availableModuleSpec();
    final title = spec == null
        ? s.moduleUnknownTitle
        : s.moduleMissingTitle(spec.name);
    final body = spec == null
        ? s.moduleUnknownBody
        : s.moduleMissingBody(spec.name);

    return Scaffold(
      backgroundColor: isDark ? cs.surface : const Color(0xFFFBFCFE),
      appBar: AppBar(title: Text(s.modules)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: MeowCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (spec != null)
                      ModuleIconBadge(
                        moduleId: spec.id,
                        size: 62,
                        iconSize: 28,
                        radius: 22,
                      )
                    else
                      Container(
                        width: 62,
                        height: 62,
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(
                            color: cs.primary.withValues(alpha: 0.20),
                          ),
                        ),
                        child: Icon(
                          Icons.extension_off_rounded,
                          size: 29,
                          color: cs.primary,
                        ),
                      ),
                    const SizedBox(height: 18),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: cs.onSurface,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      body,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                        height: 1.42,
                      ),
                    ),
                    const SizedBox(height: 22),
                    if (spec != null) ...[
                      MeowPrimaryButton(
                        label: s.installModuleAction(spec.name),
                        icon: Icons.add_rounded,
                        loading: _installingMissingModule,
                        onPressed: _installingMissingModule
                            ? null
                            : () => _installMissingModule(spec),
                      ),
                      const SizedBox(height: 10),
                    ],
                    MeowSecondaryButton(
                      label: s.moduleStore,
                      icon: Icons.view_module_rounded,
                      onPressed: () => context.push('/modules/store'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _settingVisible(ModuleModel module, MapEntry<String, bool> entry) =>
      true;

  Widget _buildSettingsSection({
    required ModuleModel module,
    required List<MapEntry<String, bool>> entries,
    required Map<String, (String, String)> settingLabels,
    required ColorScheme cs,
    required MeowExtras extras,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.featurePermission,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        if (module.id == 'device_context')
          _buildGroupedSettings(
            module: module,
            entries: entries,
            settingLabels: settingLabels,
            cs: cs,
            extras: extras,
          )
        else
          _buildFlatSettingsCard(
            module: module,
            entries: entries,
            settingLabels: settingLabels,
            cs: cs,
            extras: extras,
          ),
      ],
    );
  }

  Widget _buildFlatSettingsCard({
    required ModuleModel module,
    required List<MapEntry<String, bool>> entries,
    required Map<String, (String, String)> settingLabels,
    required ColorScheme cs,
    required MeowExtras extras,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: extras.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: extras.subtleBorder),
      ),
      child: Column(
        children: [
          for (final entry in entries)
            _buildSettingSwitch(
              entry: entry,
              label: settingLabels[entry.key],
              cs: cs,
            ),
        ],
      ),
    );
  }

  Widget _buildGroupedSettings({
    required ModuleModel module,
    required List<MapEntry<String, bool>> entries,
    required Map<String, (String, String)> settingLabels,
    required ColorScheme cs,
    required MeowExtras extras,
  }) {
    final groups = _settingGroupsFor(module, entries);
    return Column(
      children: [
        for (var i = 0; i < groups.length; i++) ...[
          _buildSettingGroupCard(
            group: groups[i],
            settingLabels: settingLabels,
            cs: cs,
            extras: extras,
          ),
          if (i != groups.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildSettingGroupCard({
    required _ModuleSettingGroup group,
    required Map<String, (String, String)> settingLabels,
    required ColorScheme cs,
    required MeowExtras extras,
  }) {
    return Container(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: extras.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: extras.subtleBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(group.icon, size: 18, color: cs.primary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                      if (group.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          group.description,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.25,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (final entry in group.entries)
            _buildSettingSwitch(
              entry: entry,
              label: settingLabels[entry.key],
              cs: cs,
            ),
        ],
      ),
    );
  }

  List<_ModuleSettingGroup> _settingGroupsFor(
    ModuleModel module,
    List<MapEntry<String, bool>> entries,
  ) {
    if (module.id != 'device_context') {
      return [
        _ModuleSettingGroup(
          title: s.featurePermission,
          description: '',
          icon: Icons.tune_rounded,
          entries: entries,
        ),
      ];
    }

    final grouped = <String, List<MapEntry<String, bool>>>{};
    for (final entry in entries) {
      grouped
          .putIfAbsent(_deviceContextGroupKey(entry.key), () => [])
          .add(entry);
    }

    const order = ['power', 'connectivity', 'apps', 'system', 'clipboard'];
    return [
      for (final key in order)
        if ((grouped[key] ?? const <MapEntry<String, bool>>[]).isNotEmpty)
          _ModuleSettingGroup(
            title: s.moduleSettingGroupTitle(module.id, key),
            description: s.moduleSettingGroupDescription(module.id, key),
            icon: _deviceContextGroupIcon(key),
            entries: grouped[key]!,
          ),
    ];
  }

  String _deviceContextGroupKey(String settingKey) {
    return switch (settingKey) {
      'allow_battery' || 'allow_charging' => 'power',
      'allow_network' || 'allow_bluetooth' => 'connectivity',
      'allow_foreground_app' ||
      'allow_open_apps' ||
      'allow_background_launch' => 'apps',
      'allow_storage' || 'allow_time_locale' || 'allow_dnd' => 'system',
      'allow_clipboard_read' || 'allow_clipboard_write' => 'clipboard',
      _ => 'system',
    };
  }

  IconData _deviceContextGroupIcon(String groupKey) {
    return switch (groupKey) {
      'power' => Icons.battery_charging_full_rounded,
      'connectivity' => Icons.hub_rounded,
      'apps' => Icons.apps_rounded,
      'clipboard' => Icons.content_paste_rounded,
      _ => Icons.memory_rounded,
    };
  }

  Widget _buildSettingSwitch({
    required MapEntry<String, bool> entry,
    required (String, String)? label,
    required ColorScheme cs,
  }) {
    return SwitchListTile(
      title: Text(
        label?.$1 ?? entry.key,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: cs.onSurface,
        ),
      ),
      subtitle: label != null
          ? Text(
              label.$2,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            )
          : null,
      value: entry.value,
      activeTrackColor: cs.primary.withValues(alpha: 0.82),
      activeThumbColor: Colors.white,
      inactiveTrackColor: cs.onSurfaceVariant.withValues(alpha: 0.22),
      inactiveThumbColor: cs.onSurfaceVariant.withValues(alpha: 0.72),
      onChanged: (v) => _toggleSetting(entry.key, v),
    );
  }

  /// Picks the index of today's prompt. Rotates deterministically every 6
  /// hours based on the wall clock, so all entry points agree without storage.
  /// The shuffle offset nudges it forward within the module's prompt list.
  int _todayPromptIndex(int promptCount) {
    if (promptCount <= 0) return 0;
    final now = DateTime.now();
    // Number of 6-hour slots since epoch — changes 4 times a day.
    final slot = now.millisecondsSinceEpoch ~/ (6 * 60 * 60 * 1000);
    return (slot + _promptShuffleOffset) % promptCount;
  }

  Future<void> _copyTodayPrompt(String prompt) async {
    await Clipboard.setData(ClipboardData(text: prompt));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(s.todayPromptCopied),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _copyTodayPromptWithFeedback(String prompt) async {
    _setPromptBorderBoosted(true);
    await _copyTodayPrompt(prompt);
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    _setPromptBorderBoosted(false);
  }

  Future<void> _sendTodayPromptToChat(String prompt) async {
    await ref.read(agentListProvider.notifier).ready;
    final agents = ref.read(agentListProvider);
    if (agents.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s.workflowNoAgentsYet)));
      return;
    }

    if (!mounted) return;
    final pickedAgentId = await MeowDropdown.showSheet<String>(
      context,
      title: s.workflowChooseAgentTitle,
      searchHint: s.workflowSearchAgentsLong,
      emptyText: s.clipboardAgentNotFound,
      strings: s,
      options: [
        for (final agent in agents)
          MeowDropdownOption<String>(
            value: agent.id,
            label: agent.name.trim().isEmpty
                ? s.workflowUntitledAgent
                : agent.name.trim(),
            prefix: MeowAgentIcon(agent: agent),
            searchText: '${agent.providerId} ${agent.model}',
          ),
      ],
    );
    if (pickedAgentId == null || !mounted) return;

    final encoded = Uri.encodeComponent(prompt);
    context.go('/agents/$pickedAgentId/chat?initialText=$encoded');
  }

  Widget _buildTodayPromptCard({
    required ModuleModel module,
    required ColorScheme cs,
    required MeowExtras extras,
  }) {
    final prompts = s.modulePrompts(module.id);
    if (prompts.isEmpty) return const SizedBox.shrink();
    final prompt = prompts[_todayPromptIndex(prompts.length)];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.primary.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.14)),
                ),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 17,
                  color: cs.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  s.todayPromptTitle,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                    height: 1.2,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildPromptHeaderAction(
                tooltip: s.clipboardActionSendToChat,
                icon: Icons.chat_bubble_outline_rounded,
                cs: cs,
                onPressed: () => _sendTodayPromptToChat(prompt),
              ),
              const SizedBox(width: 8),
              _buildPromptHeaderAction(
                tooltip: s.todayPromptShuffle,
                icon: Icons.shuffle_rounded,
                cs: cs,
                onPressed: () {
                  setState(() => _promptShuffleOffset++);
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          _AnimatedPromptBox(
            animation: _ensurePromptBorderController(),
            extras: extras,
            boosted: _promptBorderBoosted,
            onTap: () => _copyTodayPromptWithFeedback(prompt),
            onTapDown: () => _setPromptBorderBoosted(true),
            onTapCancel: () => _setPromptBorderBoosted(false),
            child: Text(
              prompt,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: cs.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            s.todayPromptSubtitle,
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPromptHeaderAction({
    required String tooltip,
    required IconData icon,
    required ColorScheme cs,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      color: cs.primary,
      style: IconButton.styleFrom(
        backgroundColor: cs.primary.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        fixedSize: const Size(36, 36),
        minimumSize: const Size(36, 36),
        padding: EdgeInsets.zero,
      ),
    );
  }

  String _moduleDescription(ModuleModel module, {required AppStrings strings}) {
    final s = strings;
    switch (module.id) {
      case 'device_context':
        return s.moduleDescDeviceContext;
      case 'notification_intelligence':
        return s.moduleDescNotification;
      case 'notes':
        return s.moduleDescNotes;
      case 'files':
        return s.moduleDescFiles;
      case 'calendar':
        return s.moduleDescCalendar;
      case 'workflows':
        return s.moduleDescWorkflows;
      case 'web':
        return s.moduleDescWeb;
      case 'vm':
        return s.moduleDescVm;
      default:
        return module.description;
    }
  }

  Map<String, (String, String)> _settingLabels(
    String moduleId, {
    required AppStrings strings,
  }) {
    final s = strings;
    final labels = <String, (String, String)>{};
    for (final entry in _module!.settings.entries) {
      labels[entry.key] = s.moduleSetting(moduleId, entry.key);
    }
    return labels;
  }
}

class _AnimatedPromptBox extends StatelessWidget {
  const _AnimatedPromptBox({
    required this.animation,
    required this.extras,
    required this.boosted,
    required this.onTap,
    required this.onTapDown,
    required this.onTapCancel,
    required this.child,
  });

  final Animation<double> animation;
  final MeowExtras extras;
  final bool boosted;
  final VoidCallback onTap;
  final VoidCallback onTapDown;
  final VoidCallback onTapCancel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final alpha = boosted ? 0.95 : 0.68;
        final saturationBoost = boosted ? 0.16 : 0.0;
        return Container(
          width: double.infinity,
          padding: EdgeInsets.all(boosted ? 2.0 : 1.4),
          decoration: BoxDecoration(
            gradient: SweepGradient(
              colors: [
                HSVColor.fromAHSV(
                  alpha,
                  214,
                  0.70 + saturationBoost,
                  0.95,
                ).toColor(),
                HSVColor.fromAHSV(
                  alpha,
                  285,
                  0.56 + saturationBoost,
                  0.96,
                ).toColor(),
                HSVColor.fromAHSV(
                  alpha,
                  330,
                  0.58 + saturationBoost,
                  0.98,
                ).toColor(),
                HSVColor.fromAHSV(
                  alpha,
                  42,
                  0.68 + saturationBoost,
                  0.98,
                ).toColor(),
                HSVColor.fromAHSV(
                  alpha,
                  155,
                  0.64 + saturationBoost,
                  0.86,
                ).toColor(),
                HSVColor.fromAHSV(
                  alpha,
                  214,
                  0.70 + saturationBoost,
                  0.95,
                ).toColor(),
              ],
              transform: GradientRotation(animation.value * math.pi * 2),
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Material(
            color: extras.inputFill,
            borderRadius: BorderRadius.circular(17),
            child: InkWell(
              onTap: onTap,
              onTapDown: (_) => onTapDown(),
              onTapCancel: onTapCancel,
              borderRadius: BorderRadius.circular(17),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: child,
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }
}

class _ModuleSettingGroup {
  const _ModuleSettingGroup({
    required this.title,
    required this.description,
    required this.icon,
    required this.entries,
  });

  final String title;
  final String description;
  final IconData icon;
  final List<MapEntry<String, bool>> entries;
}
