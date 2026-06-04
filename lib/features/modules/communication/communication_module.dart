import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'communication_service.dart';

/// Communication Automation module plugin.
///
/// Provides tools for automated calling, SMS, and contact resolution
/// via Android intents.
class CommunicationModulePlugin extends ModulePlugin {
  const CommunicationModulePlugin();

  @override
  String get moduleId => 'communication';

  @override
  String get catalogGroup => 'communication';

  @override
  List<String> get capabilityHints => const [
        'call',
        'phone',
        'sms',
        'message',
        'text',
        'contact',
        'voice call',
      ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
        // ─── Contact ───────────────────────────────────────────────
        ToolDefinition(
          name: 'communication.resolve_contact',
          description:
              'Resolve a contact name to a phone number from the device address book. '
              'Use this FIRST before sending messages or making calls when only a name is given.',
          risk: 'safe',
          requiresConfirmation: false,
          isRetrieval: true,
          inputSchema: {
            'query': 'string (contact name or partial name to search)',
          },
        ),
        ToolDefinition(
          name: 'communication.list_contacts',
          description:
              'Search or list contacts from the device address book. '
              'Returns matching contacts with names and phone numbers.',
          risk: 'safe',
          requiresConfirmation: false,
          isRetrieval: true,
          inputSchema: {
            'query': 'string (optional search query, empty for all)',
            'limit': 'int (optional, max results, default 20)',
          },
        ),

        // ─── Phone Call ────────────────────────────────────────────
        ToolDefinition(
          name: 'communication.call',
          description:
              'Make a direct phone call (regular cellular call). '
              'Requires CALL_PHONE permission.',
          risk: 'sensitive',
          requiresConfirmation: true,
          inputSchema: {
            'phone': 'string (phone number to call)',
          },
        ),

        // ─── SMS ──────────────────────────────────────────────────
        ToolDefinition(
          name: 'communication.send_sms',
          description:
              'Send an SMS message directly. Requires SEND_SMS permission.',
          risk: 'sensitive',
          requiresConfirmation: true,
          inputSchema: {
            'phone': 'string (phone number)',
            'message': 'string (SMS text, max 160 chars recommended)',
          },
        ),
      ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final service = CommunicationService();

    switch (request.name) {
      case 'communication.resolve_contact':
        return service.resolveContact(request.args);
      case 'communication.list_contacts':
        return service.listContacts(request.args);
      case 'communication.call':
        return service.makeCall(request.args);
      case 'communication.send_sms':
        return service.sendSms(request.args);
      default:
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'CommunicationModulePlugin cannot handle ${request.name}',
        );
    }
  }
}
