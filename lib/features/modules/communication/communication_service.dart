import 'package:flutter/services.dart';

import '../../../services/agent_runtime/runtime_models.dart';

/// MethodChannel bridge to native Kotlin communication service.
///
/// Handles:
/// - Contact resolution (READ_CONTACTS)
/// - WhatsApp automation (Accessibility Service)
/// - Phone calls (CALL_PHONE)
/// - SMS sending (SEND_SMS)
class CommunicationService {
  static const _channel = MethodChannel('com.meowagent/communication');

  // ─── Contacts ──────────────────────────────────────────────────────

  Future<ToolExecutionResult> resolveContact(Map<String, dynamic> args) async {
    final query = (args['query'] as String?)?.trim() ?? '';
    if (query.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.resolve_contact',
        error: 'Contact query cannot be empty.',
      );
    }

    try {
      final result = await _channel.invokeMethod<Map>('resolveContact', {
        'query': query,
      });
      final data = Map<String, dynamic>.from(result ?? {});
      if (data['found'] == true) {
        return ToolExecutionResult(
          success: true,
          toolName: 'communication.resolve_contact',
          data: {
            'found': true,
            'name': data['name'],
            'phone': data['phone'],
            'all_matches': data['all_matches'],
          },
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'communication.resolve_contact',
        data: {'found': false, 'query': query},
      );
    } on PlatformException catch (e) {
      return _permissionError('communication.resolve_contact', e);
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.resolve_contact',
        error: 'Failed to resolve contact: $e',
      );
    }
  }

  Future<ToolExecutionResult> listContacts(Map<String, dynamic> args) async {
    final query = (args['query'] as String?)?.trim() ?? '';
    final limit = (args['limit'] as int?) ?? 20;

    try {
      final result = await _channel.invokeMethod<List>('listContacts', {
        'query': query,
        'limit': limit,
      });
      final contacts = (result ?? [])
          .map((c) => Map<String, dynamic>.from(c as Map))
          .toList();
      return ToolExecutionResult(
        success: true,
        toolName: 'communication.list_contacts',
        data: {'contacts': contacts, 'count': contacts.length},
      );
    } on PlatformException catch (e) {
      return _permissionError('communication.list_contacts', e);
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.list_contacts',
        error: 'Failed to list contacts: $e',
      );
    }
  }

  // ─── WhatsApp Messaging ────────────────────────────────────────────

  Future<ToolExecutionResult> sendWhatsApp(Map<String, dynamic> args) async {
    final phone = (args['phone'] as String?)?.trim() ?? '';
    final message = (args['message'] as String?)?.trim() ?? '';

    if (phone.isEmpty || message.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.send_whatsapp',
        error: 'Both phone and message are required.',
      );
    }

    try {
      final result = await _channel.invokeMethod<Map>('sendWhatsApp', {
        'phone': _normalizePhone(phone),
        'message': message,
      });
      final data = Map<String, dynamic>.from(result ?? {});
      return ToolExecutionResult(
        success: data['success'] == true,
        toolName: 'communication.send_whatsapp',
        data: data,
        error: data['success'] != true ? (data['error'] as String?) : null,
      );
    } on PlatformException catch (e) {
      return _accessibilityError('communication.send_whatsapp', e);
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.send_whatsapp',
        error: 'Failed to send WhatsApp message: $e',
      );
    }
  }

  Future<ToolExecutionResult> sendWhatsAppGroup(
    Map<String, dynamic> args,
  ) async {
    final groupName = (args['group_name'] as String?)?.trim() ?? '';
    final message = (args['message'] as String?)?.trim() ?? '';

    if (groupName.isEmpty || message.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.send_whatsapp_group',
        error: 'Both group_name and message are required.',
      );
    }

    try {
      final result = await _channel.invokeMethod<Map>('sendWhatsAppGroup', {
        'group_name': groupName,
        'message': message,
      });
      final data = Map<String, dynamic>.from(result ?? {});
      return ToolExecutionResult(
        success: data['success'] == true,
        toolName: 'communication.send_whatsapp_group',
        data: data,
        error: data['success'] != true ? (data['error'] as String?) : null,
      );
    } on PlatformException catch (e) {
      return _accessibilityError('communication.send_whatsapp_group', e);
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.send_whatsapp_group',
        error: 'Failed to send WhatsApp group message: $e',
      );
    }
  }

  // ─── WhatsApp Calling ──────────────────────────────────────────────

  Future<ToolExecutionResult> waVoiceCall(Map<String, dynamic> args) async {
    final phone = (args['phone'] as String?)?.trim() ?? '';
    if (phone.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.wa_voice_call',
        error: 'Phone number is required.',
      );
    }

    try {
      final result = await _channel.invokeMethod<Map>('waVoiceCall', {
        'phone': _normalizePhone(phone),
      });
      final data = Map<String, dynamic>.from(result ?? {});
      return ToolExecutionResult(
        success: data['success'] == true,
        toolName: 'communication.wa_voice_call',
        data: data,
        error: data['success'] != true ? (data['error'] as String?) : null,
      );
    } on PlatformException catch (e) {
      return _accessibilityError('communication.wa_voice_call', e);
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.wa_voice_call',
        error: 'Failed to initiate WA voice call: $e',
      );
    }
  }

  Future<ToolExecutionResult> waVideoCall(Map<String, dynamic> args) async {
    final phone = (args['phone'] as String?)?.trim() ?? '';
    if (phone.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.wa_video_call',
        error: 'Phone number is required.',
      );
    }

    try {
      final result = await _channel.invokeMethod<Map>('waVideoCall', {
        'phone': _normalizePhone(phone),
      });
      final data = Map<String, dynamic>.from(result ?? {});
      return ToolExecutionResult(
        success: data['success'] == true,
        toolName: 'communication.wa_video_call',
        data: data,
        error: data['success'] != true ? (data['error'] as String?) : null,
      );
    } on PlatformException catch (e) {
      return _accessibilityError('communication.wa_video_call', e);
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.wa_video_call',
        error: 'Failed to initiate WA video call: $e',
      );
    }
  }

  // ─── Phone Call ────────────────────────────────────────────────────

  Future<ToolExecutionResult> makeCall(Map<String, dynamic> args) async {
    final phone = (args['phone'] as String?)?.trim() ?? '';
    if (phone.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.call',
        error: 'Phone number is required.',
      );
    }

    try {
      final result = await _channel.invokeMethod<Map>('makeCall', {
        'phone': phone,
      });
      final data = Map<String, dynamic>.from(result ?? {});
      return ToolExecutionResult(
        success: data['success'] == true,
        toolName: 'communication.call',
        data: data,
        error: data['success'] != true ? (data['error'] as String?) : null,
      );
    } on PlatformException catch (e) {
      return _permissionError('communication.call', e);
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.call',
        error: 'Failed to make call: $e',
      );
    }
  }

  // ─── SMS ───────────────────────────────────────────────────────────

  Future<ToolExecutionResult> sendSms(Map<String, dynamic> args) async {
    final phone = (args['phone'] as String?)?.trim() ?? '';
    final message = (args['message'] as String?)?.trim() ?? '';

    if (phone.isEmpty || message.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.send_sms',
        error: 'Both phone and message are required.',
      );
    }

    try {
      final result = await _channel.invokeMethod<Map>('sendSms', {
        'phone': phone,
        'message': message,
      });
      final data = Map<String, dynamic>.from(result ?? {});
      return ToolExecutionResult(
        success: data['success'] == true,
        toolName: 'communication.send_sms',
        data: data,
        error: data['success'] != true ? (data['error'] as String?) : null,
      );
    } on PlatformException catch (e) {
      return _permissionError('communication.send_sms', e);
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'communication.send_sms',
        error: 'Failed to send SMS: $e',
      );
    }
  }

  // ─── Helpers ───────────────────────────────────────────────────────

  /// Normalize phone number: strip spaces, ensure + prefix.
  String _normalizePhone(String phone) {
    var clean = phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    // Convert local Indonesian format to international.
    if (clean.startsWith('08')) {
      clean = '+62${clean.substring(1)}';
    } else if (!clean.startsWith('+')) {
      clean = '+$clean';
    }
    return clean;
  }

  ToolExecutionResult _permissionError(String toolName, PlatformException e) {
    return ToolExecutionResult(
      success: false,
      toolName: toolName,
      error: 'Permission denied: ${e.message}. '
          'Please grant the required permission in Settings.',
      data: {'error_type': 'permission_denied', 'details': e.message},
    );
  }

  ToolExecutionResult _accessibilityError(
    String toolName,
    PlatformException e,
  ) {
    return ToolExecutionResult(
      success: false,
      toolName: toolName,
      error: 'Accessibility Service not enabled: ${e.message}. '
          'Please enable Meow Agent Accessibility Service in device settings.',
      data: {'error_type': 'accessibility_disabled', 'details': e.message},
    );
  }
}
