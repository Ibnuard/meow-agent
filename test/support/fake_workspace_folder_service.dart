import 'package:meow_agent/services/agent_runtime/workspace_folder_service.dart';

/// No-op [WorkspaceFolderService] for tests. Does not touch the filesystem.
class FakeWorkspaceFolderService extends WorkspaceFolderService {
  @override
  Future<void> ensureFolder(String agentName) async {}
}
