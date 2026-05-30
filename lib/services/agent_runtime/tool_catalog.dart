import 'pending_action.dart';
import 'runtime_module_plugins.dart';

/// Selects a smaller tool surface for a runtime turn.
///
/// This is an accuracy-preserving fast filter: if intent confidence is low,
/// callers should use the full catalog.
class ToolCatalogSelection {
  const ToolCatalogSelection({
    required this.toolNames,
    required this.groups,
    required this.confidence,
    required this.reason,
  });

  final Set<String> toolNames;
  final Set<String> groups;
  final double confidence;
  final String reason;

  bool get isHighConfidence => confidence >= 0.75;
}

class ToolCatalog {
  ToolCatalog._();

  /// Frequently referenced catalog group keys.
  /// These match the [ModulePlugin.catalogGroup] values declared by each plugin.
  static const groupFiles = 'files';
  static const groupSystem = 'system';

  static final Map<String, Set<String>> groups = buildRuntimeModuleRegistry()
      .buildCatalogGroups();

  /// Pre-analyze selection.
  ///
  /// The analyzer needs a tool surface to classify intent, but we no longer
  /// keyword-match the user's message (that was language-specific and brittle).
  /// Instead the analyzer sees the FULL catalog (cheap slim `name: description`
  /// form) and emits a `tool_groups` hint; [fromGroups] then narrows the
  /// heavier downstream phases. Special cases:
  /// - workflow auto-execute and pending-action follow-ups still pin a known
  ///   surface deterministically (no LLM hint available there).
  static ToolCatalogSelection select({
    required String userMessage,
    PendingAction? pendingAction,
    bool isWorkflowAutoExecute = false,
  }) {
    if (isWorkflowAutoExecute) {
      return ToolCatalogSelection(
        toolNames: _allTools(),
        groups: groups.keys.toSet(),
        confidence: 0,
        reason: 'workflow uses broad catalog for accuracy',
      );
    }

    if (pendingAction != null) {
      return ToolCatalogSelection(
        toolNames: {
          pendingAction.toolName,
          ...?groups[groupFiles],
          ...?groups[groupSystem],
        },
        groups: {'pending', groupFiles, groupSystem},
        confidence: 0.9,
        reason: 'pending action follow-up',
      );
    }

    // No keyword matching: hand the analyzer the full catalog. confidence=0
    // means downstream skip-conditions (canSkipPlanner/canSkipReflect) do NOT
    // fire off this pre-analyze selection — they require the post-analyze
    // [fromGroups] selection, which reflects the model's actual classification.
    return ToolCatalogSelection(
      toolNames: _allTools(),
      groups: groups.keys.toSet(),
      confidence: 0,
      reason: 'full catalog (analyzer classifies via tool_groups)',
    );
  }

  /// Post-analyze selection driven by the analyzer's `tool_groups` hint.
  ///
  /// [analyzerGroups] are English group enums the model emitted (e.g.
  /// ["notes"], ["device"]). Unknown names are ignored. When exactly one valid
  /// group is named, confidence is high enough to enable the planner/reflect
  /// fast paths; when several or none are named, we fall back to the full
  /// catalog so accuracy is never sacrificed for token savings.
  static ToolCatalogSelection fromGroups(Iterable<String>? analyzerGroups) {
    final valid = <String>{
      for (final g in (analyzerGroups ?? const <String>[]))
        if (groups.containsKey(g.trim().toLowerCase())) g.trim().toLowerCase(),
    };

    if (valid.isEmpty) {
      return ToolCatalogSelection(
        toolNames: _allTools(),
        groups: groups.keys.toSet(),
        confidence: 0,
        reason: 'no usable tool_groups hint; full catalog fallback',
      );
    }

    final toolNames = <String>{};
    for (final g in valid) {
      toolNames.addAll(groups[g]!);
    }
    // System introspection often pivots into files (config dumps, agent specs).
    if (valid.contains(groupSystem)) {
      toolNames.addAll(groups[groupFiles] ?? const {});
    }

    // Single confidently-named group → high confidence (enables fast paths).
    // Multiple groups → moderate; still narrowed but no single-group fast path.
    final confidence = valid.length == 1 ? 0.85 : 0.7;
    return ToolCatalogSelection(
      toolNames: toolNames,
      groups: valid,
      confidence: confidence,
      reason: 'analyzer tool_groups: ${valid.join(', ')}',
    );
  }

  static Set<String> _allTools() =>
      groups.values.expand((tools) => tools).toSet();
}
