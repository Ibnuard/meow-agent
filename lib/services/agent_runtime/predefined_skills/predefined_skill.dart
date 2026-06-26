/// Structured capability profile used by the runtime-v5 skill router plan.
///
/// This is data, not a tool registry. Tool existence remains owned by
/// ModulePlugin/ToolDefinition and is validated through the runtime registry.
class PredefinedSkill {
  const PredefinedSkill({
    required this.id,
    required this.title,
    required this.summary,
    required this.toolGroups,
    required this.toolNames,
    this.useWhen = const [],
    this.avoidWhen = const [],
    this.requiredContextKeys = const [],
    this.examples = const [],
    this.relatedSkillIds = const [],
  });

  /// Stable skill id emitted by the analyzer, e.g. `meow.database`.
  final String id;

  /// Short human-readable name for diagnostics and future prompt assembly.
  final String title;

  /// One-line capability summary.
  final String summary;

  /// Analyzer `tool_groups` values this skill maps to.
  ///
  /// These are the model-facing group names from `prompt_analyze.dart`. Some
  /// names, such as `app`, are aliases resolved by ToolCatalog.
  final List<String> toolGroups;

  /// Exact registered tool names that are central to this skill.
  final List<String> toolNames;

  /// Short semantic routing hints. Keep these language-generic.
  final List<String> useWhen;

  /// Cases where a nearby skill should handle the request instead.
  final List<String> avoidWhen;

  /// Runtime context keys that may be useful before executing this skill.
  final List<String> requiredContextKeys;

  /// Compact English examples. These are intentionally short and generic.
  final List<String> examples;

  /// Other skills commonly needed with this one.
  final List<String> relatedSkillIds;
}
