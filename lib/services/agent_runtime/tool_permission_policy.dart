import '../../features/modules/data/module_model.dart';
import '../../features/modules/data/module_repository.dart';
import 'runtime_models.dart';
import 'tool_permission_requirements.dart';

enum ToolPermissionBlockReason {
  moduleMissing,
  moduleDisabled,
  settingDisabled,
}

class ToolPermissionRequirement {
  const ToolPermissionRequirement({
    required this.moduleId,
    required this.actionLabel,
    this.settingKey,
    this.settingLabel,
  });

  final String moduleId;
  final String actionLabel;
  final String? settingKey;
  final String? settingLabel;
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
    return {
      'errorCode': ToolPermissionPolicy.permissionDeniedCode,
      'reason': reason?.name,
      'moduleId': req?.moduleId,
      'moduleName': moduleName,
      'settingKey': req?.settingKey,
      'settingLabel': req?.settingLabel,
      'actionLabel': req?.actionLabel,
    };
  }

  String toErrorMessage() {
    final req = requirement;
    final reasonName = reason?.name ?? 'unknown';
    final setting = req?.settingLabel;
    final settingPart = setting == null ? '' : ' Setting: "$setting".';
    return '${ToolPermissionPolicy.permissionDeniedCode}: $reasonName. '
        'Module: "$moduleName".$settingPart '
        'Enable the module or permission first.';
  }
}

class ToolPermissionPolicy {
  ToolPermissionPolicy(this._moduleRepository);

  static const permissionDeniedCode = 'module_permission_denied';

  final ModuleRepository _moduleRepository;

  Future<ToolPermissionCheck> check(String toolName) async {
    final req = _requirements[toolName];
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
}
