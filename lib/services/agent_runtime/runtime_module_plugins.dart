import '../../features/modules/app_control/app_module.dart';
import '../../features/modules/app_agent/app_agent_module.dart';
import '../../features/modules/attachments/attachment_module.dart';
import '../../features/modules/calendar/calendar_module.dart';
import '../../features/modules/chat/chat_module.dart';
import '../../features/modules/clipboard_ai/clipboard_module.dart';
import '../../features/modules/device_context/device_module.dart';
import '../../features/modules/files/files_module.dart';
import '../../features/modules/notes/notes_module.dart';
import '../../features/modules/notification_intelligence/notification_module.dart';
import '../../features/modules/system/system_module.dart';
import '../../features/modules/web/web_module.dart';
import '../../features/modules/communication/communication_module.dart';
import '../../features/modules/workflows/workflow_module.dart';
import 'module_plugin.dart';
import 'module_registry.dart';

const List<ModulePlugin> runtimeModulePlugins = [
  AppModulePlugin(),
  AppAgentModulePlugin(),
  ClipboardModulePlugin(),
  DeviceModulePlugin(),
  NotificationModulePlugin(),
  NotesModulePlugin(),
  FilesModulePlugin(),
  CalendarModulePlugin(),
  WorkflowModulePlugin(),
  SystemModulePlugin(),
  ChatModulePlugin(),
  AttachmentModulePlugin(),
  WebModulePlugin(),
  CommunicationModulePlugin(),
];

ModuleRegistry? _cachedRegistry;

/// Returns a cached singleton [ModuleRegistry] built from
/// [runtimeModulePlugins]. Multiple callers (ToolRouter, ToolCatalog) share
/// the same instance, avoiding duplicate initialization and drift risk.
ModuleRegistry buildRuntimeModuleRegistry() =>
    _cachedRegistry ??= ModuleRegistry.fromPlugins(runtimeModulePlugins);
