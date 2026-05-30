import 'module_plugin.dart';
import 'runtime_models.dart';

/// Collects [ModulePlugin]s and derives the structures the runtime needs:
/// the flat tool registry, the catalog group map, and a reverse tool→plugin
/// index for dispatch.
///
/// This is the single source of truth for "what tools exist". The [ToolRouter]
/// and [ToolCatalog] consume it instead of hand-maintaining parallel copies,
/// which removes the registry/dispatch/catalog sync hazard.
class ModuleRegistry {
  ModuleRegistry(this.plugins) {
    for (final plugin in plugins) {
      for (final def in plugin.toolDefinitions) {
        final existing = _pluginByTool[def.name];
        if (existing != null) {
          throw StateError(
            'Duplicate tool "${def.name}" registered by both '
            '"${existing.moduleId}" and "${plugin.moduleId}".',
          );
        }
        _pluginByTool[def.name] = plugin;
        _definitions[def.name] = def;
      }
    }
  }

  final List<ModulePlugin> plugins;
  final Map<String, ModulePlugin> _pluginByTool = {};
  final Map<String, ToolDefinition> _definitions = {};

  /// Flat name→definition map (the router's registry).
  Map<String, ToolDefinition> buildRegistry() =>
      Map<String, ToolDefinition>.from(_definitions);

  /// Catalog group → tool names (the catalog's groups map).
  Map<String, Set<String>> buildCatalogGroups() {
    final out = <String, Set<String>>{};
    for (final plugin in plugins) {
      out
          .putIfAbsent(plugin.catalogGroup, () => <String>{})
          .addAll(plugin.toolNames);
    }
    return out;
  }

  /// English-only capability hints per catalog group (Stage 4 shortlisting).
  Map<String, List<String>> buildCapabilityHints() {
    final out = <String, List<String>>{};
    for (final plugin in plugins) {
      if (plugin.capabilityHints.isEmpty) continue;
      out
          .putIfAbsent(plugin.catalogGroup, () => <String>[])
          .addAll(plugin.capabilityHints);
    }
    return out;
  }

  /// Reverse lookup for dispatch. Null when no plugin owns [toolName].
  ModulePlugin? pluginFor(String toolName) => _pluginByTool[toolName];

  /// All tool names across every plugin.
  Set<String> get allToolNames => _definitions.keys.toSet();
}
