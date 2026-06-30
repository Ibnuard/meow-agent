import 'classifier.dart';
import 'ecosystem_snapshot.dart';
import 'language_detector.dart';
import 'pending_action.dart';
import 'runtime_logger.dart';
import 'runtime_models.dart';

/// Thin wrapper around [Classifier] that the runtime engine calls instead of
/// the 3-phase analyze→reflect→plan sequence.
///
/// Extracted to its own file to keep [AgentRuntimeEngine] lean.
/// See codebase_analysis.md P0/L3: Merge analyze+reflect+plan.
class ClassifyPhase {
  ClassifyPhase({required this.classifier});

  final Classifier classifier;

  Future<ClassifyResult> run({
    required String userMessage,
    required AgentWorkspace workspace,
    required EcosystemSnapshot snapshot,
    required List<ToolDefinition> availableTools,
    required DetectedLanguage language,
    required RuntimeLogger logger,
    required String stableContext,
    List<Map<String, String>> recentMessages = const [],
    PendingAction? pendingAction,
    String recentToolMemory = '',
    bool isWorkflowAutoExecute = false,
    String activeTaskContext = '',
    String agentName = '',
    String agentId = '',
    bool userNotIntroduced = false,
  }) {
    return classifier.classify(
      userMessage: userMessage,
      workspace: workspace,
      snapshot: snapshot,
      availableTools: availableTools,
      language: language,
      logger: logger,
      stableContext: stableContext,
      recentMessages: recentMessages,
      pendingAction: pendingAction,
      recentToolMemory: recentToolMemory,
      isWorkflowAutoExecute: isWorkflowAutoExecute,
      activeTaskContext: activeTaskContext,
      agentName: agentName,
      agentId: agentId,
      userNotIntroduced: userNotIntroduced,
    );
  }
}
