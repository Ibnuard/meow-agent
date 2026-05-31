import 'ecosystem_snapshot.dart';
import 'language_detector.dart';
import 'runtime_models.dart';
import 'snapshot_target_resolver.dart';
import 'target_reference_utils.dart';
import 'tool_verbalizer.dart';

/// Deterministic pre-flight checker that catches typos / non-existent targets
/// before the confirmation gate fires.
///
/// Pure functions — no shared mutable state, takes everything as parameters,
/// returns `String?`. Zero risk of behavioral regression on extraction.
class PreflightChecker {
  PreflightChecker({
    required Future<EcosystemSnapshot> Function() snapshotBuilder,
  }) : _snapshotBuilder = snapshotBuilder;

  final Future<EcosystemSnapshot> Function() _snapshotBuilder;

  /// Returns null when clean, or a localized clarify/block message.
  ///
  /// Inspects [ToolDefinition] runtime metadata and validates snapshot-backed
  /// targets through [SnapshotTargetResolver].
  Future<String?> check({
    required ToolCallRequest tool,
    required ToolDefinition definition,
    required ToolVerbalizer verbalizer,
    required DetectedLanguage language,
    required String userMessage,
  }) async {
    final operation = _operationForTool(definition, tool.name);
    final entityType = _entityTypeForTool(definition, tool.name);
    if (!_requiresExistingTargetPreflight(operation) && entityType != 'file') {
      return null;
    }

    final snapshot = await _snapshotBuilder();
    if (snapshot.isEmpty) return null;

    final embeddedReferenceCheck = await _preflightEmbeddedSnapshotReferences(
      tool: tool,
      definition: definition,
      snapshot: snapshot,
      verbalizer: verbalizer,
      language: language,
      userMessage: userMessage,
    );
    if (embeddedReferenceCheck != null) return embeddedReferenceCheck;

    if (!_requiresExistingTargetPreflight(operation)) return null;
    if (!SnapshotTargetResolver.isSnapshotBacked(entityType)) return null;

    final labelSelector = _labelSelectorValue(tool, definition, entityType);
    if (labelSelector == null) return null;

    final match = SnapshotTargetResolver.resolve(
      snapshot: snapshot,
      entityType: entityType,
      entityLabel: labelSelector.value,
    );
    if (match.isExact) return null;

    return verbalizer.clarifyTarget(
      entityType: entityType,
      userTyped: labelSelector.value,
      suggestion: match.isAmbiguous ? match.label : null,
      available: match.suggestions,
      language: language,
    );
  }

  Future<String?> _preflightEmbeddedSnapshotReferences({
    required ToolCallRequest tool,
    required ToolDefinition definition,
    required EcosystemSnapshot snapshot,
    required ToolVerbalizer verbalizer,
    required DetectedLanguage language,
    required String userMessage,
  }) async {
    final entityType = _entityTypeForTool(definition, tool.name);
    if (entityType != 'file' || snapshot.agents.isEmpty) return null;

    for (final key in _selectorKeysFor(definition, entityType)) {
      final raw = tool.args[key];
      if (raw is! String || raw.trim().isEmpty) continue;
      final peerPath = TargetReferenceUtils.parsePeerAgentPath(raw);
      if (peerPath == null) continue;

      final typedName = TargetReferenceUtils.displayNameFromWorkspaceSegment(
        peerPath.agentSegment,
      );
      final candidates = SnapshotTargetResolver.candidates(
        snapshot,
        'agent',
      ).map((candidate) => candidate.label).toList();
      final match = SnapshotTargetResolver.resolve(
        snapshot: snapshot,
        entityType: 'agent',
        entityLabel: typedName,
      );

      if (match.isExact) {
        final userNamedExactAgent =
            TargetReferenceUtils.messageMentionsExactAgent(
              userMessage,
              match.label,
            );
        if (!userNamedExactAgent) {
          return verbalizer.clarifyTarget(
            entityType: 'agent',
            userTyped: typedName,
            suggestion: match.label,
            available: candidates,
            language: language,
          );
        }
        tool.args[key] = TargetReferenceUtils.canonicalPeerAgentPath(
          peerPath,
          match.label,
        );
        continue;
      }

      return verbalizer.clarifyTarget(
        entityType: 'agent',
        userTyped: typedName,
        suggestion: match.isAmbiguous ? match.label : null,
        available: match.suggestions.isNotEmpty
            ? match.suggestions
            : candidates,
        language: language,
      );
    }

    return null;
  }

  bool _requiresExistingTargetPreflight(String operation) {
    switch (operation) {
      case 'delete':
      case 'update':
      case 'rename':
      case 'toggle':
      case 'read':
      case 'get':
        return true;
      default:
        return false;
    }
  }

  String _operationForTool(ToolDefinition definition, String toolName) {
    if (definition.operation.isNotEmpty) return definition.operation;
    final name = toolName.toLowerCase();
    if (name.contains('.delete')) return 'delete';
    if (name.contains('.update')) return 'update';
    if (name.contains('.rename')) return 'rename';
    if (name.contains('.toggle')) return 'toggle';
    if (name.endsWith('.read')) return 'read';
    if (name.endsWith('.get')) return 'get';
    if (name.endsWith('.list')) return 'list';
    if (name.contains('.create')) return 'create';
    return '';
  }

  String _entityTypeForTool(ToolDefinition definition, String toolName) {
    if (definition.targetEntity.isNotEmpty) return definition.targetEntity;
    if (toolName.startsWith('system.agents.')) return 'agent';
    if (toolName.startsWith('workflow.')) return 'workflow';
    if (toolName.startsWith('system.providers.')) return 'provider';
    if (toolName.startsWith('system.modules.')) return 'module';
    return '';
  }

  _SelectorValue? _labelSelectorValue(
    ToolCallRequest tool,
    ToolDefinition definition,
    String entityType,
  ) {
    for (final key in _selectorKeysFor(definition, entityType)) {
      if (_isIdSelectorKey(key)) continue;
      final value = tool.args[key];
      if (value is String && value.trim().isNotEmpty) {
        return _SelectorValue(value.trim());
      }
    }
    return null;
  }

  List<String> _selectorKeysFor(ToolDefinition definition, String entityType) {
    if (definition.selectorArgs.isNotEmpty) return definition.selectorArgs;
    switch (entityType) {
      case 'agent':
        return const ['name', 'agentName', 'label', 'target'];
      case 'workflow':
        return const ['title', 'workflowName', 'label', 'target', 'id'];
      case 'provider':
        return const ['nickname', 'provider', 'providerName', 'label', 'id'];
      case 'module':
        return const ['id', 'module', 'moduleId', 'label'];
      case 'file':
        return const ['path', 'from', 'to'];
      default:
        return const ['name', 'title', 'label', 'target'];
    }
  }

  bool _isIdSelectorKey(String key) {
    final lower = key.toLowerCase();
    return lower == 'id' || lower.endsWith('id') || lower.endsWith('_id');
  }
}

class _SelectorValue {
  const _SelectorValue(this.value);

  final String value;
}