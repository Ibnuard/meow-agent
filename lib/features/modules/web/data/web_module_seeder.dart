import 'package:uuid/uuid.dart';

import '../../workflows/workflow_model.dart';
import '../../workflows/workflow_repository.dart';
import 'api_config.dart';
import 'api_store_repository.dart';

/// Seeds a sample API and workflow when the Web (API Store) module is installed.
///
/// Both the sample API and sample workflow are user-deletable. This only runs
/// once — if a sample API with the same name already exists, it skips seeding.
class WebModuleSeeder {
  WebModuleSeeder._();

  static const _sampleApiName = 'Sample Posts API';
  static const _sampleApiUrl = 'https://jsonplaceholder.typicode.com/posts/1';

  /// Seed sample data. Safe to call multiple times — idempotent.
  static Future<void> seed({required String agentId}) async {
    final repo = ApiStoreRepository.instance;

    // Check if already seeded.
    final existing = await repo.findByName(_sampleApiName);
    if (existing != null) return;

    // 1. Seed sample API config.
    final sampleApi = ApiConfig(
      id: ApiConfig.generateId(),
      name: _sampleApiName,
      url: _sampleApiUrl,
      method: 'GET',
      auth: const ApiAuth(),
      headers: const [],
      queryParams: const [],
      bodyMode: BodyMode.none,
    );
    await repo.save(sampleApi);

    // 2. Seed sample workflow that uses the API.
    final workflowRepo = WorkflowRepository();
    final workflowId = const Uuid().v4();
    final sampleWorkflow = WorkflowModel(
      id: workflowId,
      agentId: agentId,
      title: 'API Call Sample',
      prompt:
          'Here is data from the API Store:\n\n'
          '@api:Sample_Posts_API\n\n'
          'Summarize the post title and body above in a concise, friendly '
          'message to the user. If the API response shows an error, explain '
          'what went wrong.',
      trigger: const TriggerConfig(
        type: TriggerType.interval,
        intervalMinutes: 360,
      ),
      notification: const NotifConfig(
        style: NotifStyle.normal,
        showResult: true,
      ),
      sendToChat: true,
      enabled: false, // Disabled by default — user activates when ready.
      templateId: 'tpl_api_call_sample',
      createdAt: DateTime.now(),
    );
    await workflowRepo.create(sampleWorkflow);
  }
}
