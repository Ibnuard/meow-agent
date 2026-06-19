import '../../features/modules/agent/agent_domain_module.dart';
import '../../features/modules/attachments/attachment_module.dart';
import '../../features/modules/calendar/calendar_module.dart';
import '../../features/modules/chat/chat_module.dart';
import '../../features/modules/device_context/device_module.dart';
import '../../features/modules/files/files_module.dart';
import '../../features/modules/notes/notes_module.dart';
import '../../features/modules/notification_intelligence/notification_module.dart';
import '../../features/modules/provider/provider_domain_module.dart';
import '../../features/modules/sqlite/sqlite_query_module.dart';
import '../../features/modules/system/system_module.dart';
import '../../features/modules/web/web_module.dart';
import '../../features/modules/communication/communication_module.dart';
import '../../features/modules/workflows/workflow_module.dart';
import '../../features/modules/db/db_module.dart';
import 'module_plugin.dart';
import 'module_registry.dart';

const List<ModulePlugin> runtimeModulePlugins = [
  DeviceModulePlugin(),
  NotificationModulePlugin(),
  NotesModulePlugin(),
  FilesModulePlugin(),
  CalendarModulePlugin(),
  WorkflowModulePlugin(),
  // New domain-specific tool surface (Phase 3 architecture migration).
  // Replaces system.config.patch for agent and provider mutations.
  AgentDomainModulePlugin(),
  ProviderDomainModulePlugin(),
  SystemModulePlugin(),
  SqliteQueryModulePlugin(),
  ChatModulePlugin(),
  AttachmentModulePlugin(),
  WebModulePlugin(),
  // VmModulePlugin(),
  CommunicationModulePlugin(),
  DatabaseModulePlugin(),
];

ModuleRegistry? _cachedRegistry;

/// Returns a cached singleton [ModuleRegistry] built from
/// [runtimeModulePlugins]. Multiple callers (ToolRouter, ToolCatalog) share
/// the same instance, avoiding duplicate initialization and drift risk.
ModuleRegistry buildRuntimeModuleRegistry() =>
    _cachedRegistry ??= ModuleRegistry.fromPlugins(runtimeModulePlugins);
