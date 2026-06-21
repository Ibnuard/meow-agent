import 'package:flutter/services.dart';

class BubbleNarrativeService {
  BubbleNarrativeService._();

  static const _channel = MethodChannel('com.meowagent/bubble');

  static Future<void> send(String text) async {
    if (text.trim().isEmpty) return;
    try {
      await _channel.invokeMethod('sendNarrative', {'text': text});
    } catch (_) {
      // Bubble overlay is optional; automation must continue if it is absent.
    }
  }
}
