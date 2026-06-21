import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/tool_permission_requirements.dart';
import 'package:meow_agent/services/agent_runtime/tool_router.dart';

/// Guards against the permission gate's fail-open default.
///
/// [ToolPermissionPolicy.check] returns `allowed()` for any tool NOT covered by
/// an exact [toolPermissionRequirements] entry OR a
/// [toolPermissionPrefixRequirements] prefix rule. That means an uncovered tool
/// is ungated — a silent security hole.
///
/// This test asserts: every registered tool is gated (exact or prefix) OR in
/// the explicit allowlist below. A new tool that is neither fails this test,
/// forcing a deliberate decision (gate it, or document why it is ungated).
void main() {
  // Tools intentionally NOT gated. Each is here for a documented reason: a safe
  // read-only tool, a confirmation-gated mutator (backstopped by
  // requiresConfirmation), or a core self-management surface on a module that
  // has no user-facing toggle (agent/provider/system/sqlite/chat/attachment).
  //
  // To add a tool here you must justify why it does not need a module/setting
  // gate. Prefer adding a gate entry over expanding this list.
  const intentionallyUngated = <String>{
    // ─── Safe read-only tools (no mutation, no sensitive egress) ───────────
    'agent.list',
    'agent.soul.read',
    'attachment.list',
    'attachment.read_text',
    'attachment.describe_image',
    'calendar.upcoming',
    'calendar.conflicts',
    'calendar.free_slot',
    'files.metadata',
    'files.search',
    'files.tree',
    'provider.list',
    'sqlite.query',
    'system.self',
    'system.rtb',
    'system.config.read',
    'system.export_all',
    'system.memory.search',
    'system.tools.list',
    'system.workspace.read',
    'system.workspace.schema',

    // ─── Confirmation-gated mutators (requiresConfirmation: true backstop) ──
    'agent.create',
    'agent.delete',
    'provider.create',
    'provider.delete',
    'provider.update',
    'system.config.patch',
    'system.import',

    // ─── Core self-management surfaces (no user-facing module toggle) ───────
    // These modules (agent/provider/system/chat) are agent self-management and
    // are not in ModuleRegistry.available, so a moduleId gate would always
    // resolve to moduleMissing and hard-block them.
    'agent.update',
    'chat.send',
    'system.profile.update',
    'system.memory.append',
  };

  /// Mirror of [ToolPermissionPolicy]'s resolution: a tool is gated if it has an
  /// exact entry OR matches a prefix rule.
  bool isGated(String tool) {
    if (toolPermissionRequirements.containsKey(tool)) return true;
    return toolPermissionPrefixRequirements.keys.any(tool.startsWith);
  }

  test('every registered tool is gated or explicitly allowlisted', () {
    final router = ToolRouter();
    final registered = router.registeredTools.toSet();

    final ungated = registered.where((t) => !isGated(t)).toSet();
    final unexpected = ungated.difference(intentionallyUngated);

    expect(
      unexpected,
      isEmpty,
      reason:
          'These registered tools are neither gated (exact or prefix) nor listed '
          'in intentionallyUngated. The permission gate fails OPEN for them. Add '
          'a gate entry, or (if truly safe) add them to the allowlist with a '
          'justification:\n  ${unexpected.join('\n  ')}',
    );
  });

  test('allowlist has no stale entries', () {
    final router = ToolRouter();
    final registered = router.registeredTools.toSet();

    // An allowlisted tool that is now gated, or no longer registered, is dead
    // weight that hides intent. Keep the list honest.
    final staleGated =
        intentionallyUngated.where(isGated).toSet();
    expect(
      staleGated,
      isEmpty,
      reason: 'Allowlisted tools that are now gated (remove from allowlist):\n'
          '  ${staleGated.join('\n  ')}',
    );

    final staleUnregistered = intentionallyUngated.difference(registered);
    expect(
      staleUnregistered,
      isEmpty,
      reason: 'Allowlisted tools that are no longer registered:\n'
          '  ${staleUnregistered.join('\n  ')}',
    );
  });

  test('gate map has no entries for unregistered tools', () {
    final router = ToolRouter();
    final registered = router.registeredTools.toSet();
    final gated = toolPermissionRequirements.keys.toSet();

    final orphanGates = gated.difference(registered);
    expect(
      orphanGates,
      isEmpty,
      reason: 'Gate entries for tools that are not registered (drift):\n'
          '  ${orphanGates.join('\n  ')}',
    );
  });

  test('every prefix rule matches at least one registered tool', () {
    final router = ToolRouter();
    final registered = router.registeredTools.toSet();

    for (final prefix in toolPermissionPrefixRequirements.keys) {
      final matches = registered.where((t) => t.startsWith(prefix));
      expect(
        matches,
        isNotEmpty,
        reason: 'Prefix rule "$prefix" matches no registered tool (dead rule).',
      );
    }
  });
}

