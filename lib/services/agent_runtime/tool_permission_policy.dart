import '../../features/modules/data/module_model.dart';
import '../../features/modules/data/module_repository.dart';
import '../permission/permission_manager.dart';
import 'runtime_models.dart';
import 'tool_permission_requirements.dart';

enum ToolPermissionBlockReason {
  moduleMissing,
  moduleDisabled,
  settingDisabled,
  androidPermissionDenied,
}

class ToolPermissionRequirement {
  const ToolPermissionRequirement({
    required this.moduleId,
    required this.actionLabel,
    this.settingKey,
    this.settingLabel,
    this.androidPermission,
  });

  final String moduleId;
  final String actionLabel;
  final String? settingKey;
  final String? settingLabel;

  /// Optional Android runtime permission required for this tool.
  /// When set, [ToolPermissionPolicy] checks this permission before allowing
  /// the tool to execute, preventing runtime crashes.
  final PermissionType? androidPermission;
}

class ToolPermissionCheck {
  const ToolPermissionCheck.allowed()
    : allowed = true,
      requirement = null,
      reason = null,
      module = null,
      moduleSpec = null;

  const ToolPermissionCheck.blocked({
    required this.requirement,
    required this.reason,
    required this.moduleSpec,
    this.module,
  }) : allowed = false;

  final bool allowed;
  final ToolPermissionRequirement? requirement;
  final ToolPermissionBlockReason? reason;
  final ModuleModel? module;
  final ModuleModel? moduleSpec;

  String get moduleName => moduleSpec?.name ?? requirement?.moduleId ?? '';

  Map<String, dynamic> toData() {
    final req = requirement;
    final androidPerm = req?.androidPermission;
    return {
      'errorCode': ToolPermissionPolicy.permissionDeniedCode,
      'reason': reason?.name,
      'moduleId': req?.moduleId,
      'moduleName': moduleName,
      'settingKey': req?.settingKey,
      'settingLabel': req?.settingLabel,
      'actionLabel': req?.actionLabel,
      if (androidPerm != null) 'androidPermission': androidPerm.name,
    };
  }

  String toErrorMessage() {
    final req = requirement;
    final reasonName = reason?.name ?? 'unknown';
    final setting = req?.settingLabel;
    final settingPart = setting == null ? '' : ' Setting: "$setting".';
    final androidPerm = req?.androidPermission;
    final androidPart =
        androidPerm == null ||
            reason != ToolPermissionBlockReason.androidPermissionDenied
        ? ''
        : ' Android permission "${androidPerm.name}" is not granted.';
    return '${ToolPermissionPolicy.permissionDeniedCode}: $reasonName. '
        'Module: "$moduleName".$settingPart$androidPart '
        'Enable the module or permission first.';
  }
}

class ToolPermissionPolicy {
  ToolPermissionPolicy(
    this._moduleRepository, {
    PermissionManager? permissionManager,
  }) : _permissionManager = permissionManager ?? PermissionManager();

  static const permissionDeniedCode = 'module_permission_denied';

  final ModuleRepository _moduleRepository;
  final PermissionManager _permissionManager;

  Future<ToolPermissionCheck> check(String toolName) async {
    final req = _requirementFor(toolName);
    if (req == null) return const ToolPermissionCheck.allowed();

    final modules = await _moduleRepository.getInstalled();
    final module = modules.where((m) => m.id == req.moduleId).firstOrNull;
    final spec = ModuleRegistry.available
        .where((m) => m.id == req.moduleId)
        .firstOrNull;

    if (module == null) {
      return ToolPermissionCheck.blocked(
        requirement: req,
        reason: ToolPermissionBlockReason.moduleMissing,
        moduleSpec: spec,
      );
    }
    if (!module.enabled) {
      return ToolPermissionCheck.blocked(
        requirement: req,
        reason: ToolPermissionBlockReason.moduleDisabled,
        module: module,
        moduleSpec: spec ?? module,
      );
    }

    final settingKey = req.settingKey;
    if (settingKey != null && module.settings[settingKey] != true) {
      return ToolPermissionCheck.blocked(
        requirement: req,
        reason: ToolPermissionBlockReason.settingDisabled,
        module: module,
        moduleSpec: spec ?? module,
      );
    }

    // Check Android runtime permission if the tool requires one.
    final androidPermission = req.androidPermission;
    if (androidPermission != null) {
      final permResult = await _permissionManager.check(androidPermission);
      if (permResult != PermissionResult.granted) {
        return ToolPermissionCheck.blocked(
          requirement: req,
          reason: ToolPermissionBlockReason.androidPermissionDenied,
          module: module,
          moduleSpec: spec ?? module,
        );
      }
    }

    return const ToolPermissionCheck.allowed();
  }

  Future<ToolExecutionResult?> deniedResult(String toolName) async {
    final result = await check(toolName);
    if (result.allowed) return null;
    return ToolExecutionResult(
      success: false,
      toolName: toolName,
      data: result.toData(),
      error: result.toErrorMessage(),
    );
  }

  static Map<String, ToolPermissionRequirement> get _requirements =>
      toolPermissionRequirements;

  /// Resolve the requirement for a tool: exact entry first, then a prefix rule
  /// (e.g. `app_agent.` gates every `app_agent.*` tool under one toggle). The
  /// prefix rule means new tools in a gated family are covered automatically —
  /// they can never silently fail open.
  ToolPermissionRequirement? _requirementFor(String toolName) {
    final exact = _requirements[toolName];
    if (exact != null) return exact;
    for (final entry in toolPermissionPrefixRequirements.entries) {
      if (toolName.startsWith(entry.key)) return entry.value;
    }
    return null;
  }
}
