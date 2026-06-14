import 'permission_manager.dart';

/// Central map: (moduleId, settingKey) → required Android permission.
///
/// This is the single source of truth for which module-toggle settings
/// require an Android runtime permission before they can be turned ON.
/// Consumed by:
///   1. `PermissionGatedToggleHandlerMixin` — gates toggle-ON in UI
///   2. `ModulePermissionReconciler` — auto-flips to OFF on permission revoke
///
/// To add a new gated setting: add one entry here. No other file edits needed.
const Map<({String moduleId, String settingKey}), PermissionType>
    settingPermissionRequirements = {
  // ─── Files module — all keys require storage ─────────────────────────────
  (moduleId: 'files', settingKey: 'allow_create'): PermissionType.storage,
  (moduleId: 'files', settingKey: 'allow_read'): PermissionType.storage,
  (moduleId: 'files', settingKey: 'allow_write'): PermissionType.storage,
  (moduleId: 'files', settingKey: 'allow_delete'): PermissionType.storage,
  (moduleId: 'files', settingKey: 'allow_organize'): PermissionType.storage,

  // ─── Notes module — same storage gate ────────────────────────────────────
  (moduleId: 'notes', settingKey: 'allow_create'): PermissionType.storage,
  (moduleId: 'notes', settingKey: 'allow_read'): PermissionType.storage,
  (moduleId: 'notes', settingKey: 'allow_search'): PermissionType.storage,
  (moduleId: 'notes', settingKey: 'allow_export'): PermissionType.storage,

  // ─── Device Context — bluetooth ──────────────────────────────────────────
  (moduleId: 'device_context', settingKey: 'allow_bluetooth'):
      PermissionType.bluetoothConnect,

  // ─── Super Power — overlay for agentic border ───────────────────────────
  (moduleId: 'super_power', settingKey: 'app_agentic'):
      PermissionType.systemAlertWindow,
  (moduleId: 'super_power', settingKey: 'overlay_bubble'):
      PermissionType.systemAlertWindow,

  // ─── Communication — call / sms / contacts ───────────────────────────────
  (moduleId: 'communication', settingKey: 'call_enabled'):
      PermissionType.callPhone,
  (moduleId: 'communication', settingKey: 'sms_enabled'):
      PermissionType.sendSms,
  (moduleId: 'communication', settingKey: 'contact_access'):
      PermissionType.contacts,
};

/// Look up the required Android permission for a module setting.
/// Returns null if the setting is not permission-gated.
PermissionType? requiredPermissionFor(String moduleId, String settingKey) {
  return settingPermissionRequirements[(
    moduleId: moduleId,
    settingKey: settingKey,
  )];
}

/// Find all (moduleId, settingKey) pairs that require a given permission.
/// Used by the reconciler to know which settings to auto-disable when a
/// permission is revoked.
Iterable<({String moduleId, String settingKey})> settingsRequiring(
  PermissionType permission,
) {
  return settingPermissionRequirements.entries
      .where((e) => e.value == permission)
      .map((e) => e.key);
}
