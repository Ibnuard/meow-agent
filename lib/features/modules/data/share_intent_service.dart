import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Service to receive shared text from Android via platform channel.
class ShareIntentService {
  static const _channel = MethodChannel('com.meowagent/share');

  /// Check if there's shared text from an incoming intent.
  Future<String?> getSharedText() async {
    try {
      final text = await _channel.invokeMethod<String>('getSharedText');
      return text;
    } on PlatformException {
      return null;
    }
  }
}

final shareIntentServiceProvider = Provider<ShareIntentService>(
  (ref) => ShareIntentService(),
);
