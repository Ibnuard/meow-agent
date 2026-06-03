import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'communication_service.dart';

/// Communication Automation module plugin.
///
/// Provides tools for automated messaging (WhatsApp, SMS), calling,
/// and contact resolution via Android Accessibility Service and intents.
class CommunicationModulePlugin extends ModulePlugin {
  const CommunicationModulePlugin();

  @override
  String get moduleId => 'communication';

  @override
  String get catalogGroup => 'communication';

  @override
  List<String> get capabilityHints => const [
        'whatsapp',
        'wa',
        'call',
        'phone',
        'sms',
        'message',
        'text',
        'contact',
        'telegram',
        'video call',
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

        // ─── WhatsApp Messaging ────────────────────────────────────
        ToolDefinition(
          name: 'communication.send_whatsapp',
          description:
              'Send a WhatsApp message to a contact. Requires phone number '
              '(use communication.resolve_contact first if only name is known). '
              'Uses Accessibility Service for fully automated sending.',
          risk: 'sensitive',
          requiresConfirmation: true,
          inputSchema: {
            'phone': 'string (phone number with country code, e.g. +6281234567890)',
            'message': 'string (message text to send)',
          },
        ),
        ToolDefinition(
          name: 'communication.send_whatsapp_group',
          description:
              'Send a WhatsApp message to a group by group name. '
              'Uses Accessibility Service to find the group and send.',
          risk: 'sensitive',
          requiresConfirmation: true,
          inputSchema: {
            'group_name': 'string (exact or partial group name)',
            'message': 'string (message text to send)',
          },
        ),

        // ─── WhatsApp Calling ──────────────────────────────────────
        ToolDefinition(
          name: 'communication.wa_voice_call',
          description:
              'Initiate a WhatsApp voice call to a contact. '
              'Requires phone number (resolve first if only name).',
          risk: 'sensitive',
          requiresConfirmation: true,
          inputSchema: {
            'phone': 'string (phone number with country code)',
          },
        ),
        ToolDefinition(
          name: 'communication.wa_video_call',
          description:
              'Initiate a WhatsApp video call to a contact. '
              'Requires phone number (resolve first if only name).',
          risk: 'sensitive',
          requiresConfirmation: true,
          inputSchema: {
            'phone': 'string (phone number with country code)',
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

        // ─── Telegram (Coming Soon) ───────────────────────────────
        ToolDefinition(
          name: 'communication.send_telegram',
          description:
              '[COMING SOON] Send a Telegram message. This feature is under development.',
          risk: 'sensitive',
          requiresConfirmation: true,
          inputSchema: {
            'contact': 'string (contact name or username)',
            'message': 'string (message text)',
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
      case 'communication.send_whatsapp':
        return service.sendWhatsApp(request.args);
      case 'communication.send_whatsapp_group':
        return service.sendWhatsAppGroup(request.args);
      case 'communication.wa_voice_call':
        return service.waVoiceCall(request.args);
      case 'communication.wa_video_call':
        return service.waVideoCall(request.args);
      case 'communication.call':
        return service.makeCall(request.args);
      case 'communication.send_sms':
        return service.sendSms(request.args);
      case 'communication.send_telegram':
        return _comingSoon(request.name, 'Telegram');
      default:
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'CommunicationModulePlugin cannot handle ${request.name}',
        );
    }
  }

  ToolExecutionResult _comingSoon(String toolName, String feature) {
    return ToolExecutionResult(
      success: false,
      toolName: toolName,
      error: '$feature integration is coming soon. '
          'This feature is currently under development.',
      data: {'status': 'coming_soon', 'feature': feature},
    );
  }
}
