import 'package:meow_agent/services/agent_runtime/runtime_models.dart';
import 'package:meow_agent/services/agent_runtime/workspace_loader.dart';

/// In-memory [WorkspaceLoader] for tests.
///
/// Returns canned SOUL/MEMORY/SKILLS/HEARTBEAT content with no filesystem
/// access, and no-ops all writes (ensureWorkspace, updateHeartbeat,
/// maybeFillPreferredLanguage). The default SOUL has a filled User Identity >
/// Name so the introduction gate does not fire during scenario runs; pass
/// [soul] to override (e.g. to exercise the introduction gate).
class FakeWorkspaceLoader extends WorkspaceLoader {
  FakeWorkspaceLoader({
    String? soul,
    this.memory = '# MEMORY.md\n\nNo memories recorded yet.\n',
    this.skills = '# SKILLS.md\n',
    this.heartbeat = '# HEARTBEAT.md\n',
  }) : soul = soul ?? _defaultFilledSoul;

  String soul;
  String memory;
  String skills;
  String heartbeat;

  static const _defaultFilledSoul = '''# SOUL.md

## Agent Identity

Name: TestAgent
Role: Android-native personal AI assistant.

---

## User Identity

Name: Tester
Nickname: T
Preferred Language: English
Timezone: UTC
''';

  @override
  Future<AgentWorkspace> load(String agentName) async => AgentWorkspace(
    soul: soul,
    memory: memory,
    skills: skills,
    heartbeat: heartbeat,
  );

  @override
  Future<AgentWorkspace> loadById(String agentId, {String? agentName}) async =>
      load(agentName ?? agentId);

  @override
  Future<void> ensureWorkspace(
    String agentName, {
    String languageCode = 'id',
  }) async {}

  @override
  Future<void> updateHeartbeat(
    String agentName, {
    required String state,
    required String task,
    String? lastTool,
    String? lastResult,
    String? lastError,
  }) async {}

  @override
  Future<void> maybeFillPreferredLanguage(
    String agentName,
    String languageLabel,
  ) async {}
}
