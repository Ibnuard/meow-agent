import 'package:flutter/services.dart';

import '../../features/modules/data/pin_storage_service.dart';

/// Thin Flutter wrapper around the native ShizukuManager device-control methods
/// (`wakeAndUnlock`, `lockDevice`, `isScreenOn`, `isDeviceLocked`).
///
/// Used by the Super Power / App Agent runtime to manage the device lock state
/// while running automated workflows on a locked device.
class ShizukuDeviceService {
  ShizukuDeviceService();

  static const _channel = MethodChannel('com.meowagent/shizuku');

  final _pinStorage = PinStorageService.instance;

  // ── Wake / Unlock ──────────────────────────────────────────────────────

  /// Wakes the device (turns the screen on) and dismisses the keyguard using
  /// the stored device PIN. Returns `true` when the device is confirmed awake
  /// and unlocked.
  ///
  /// Safety: the PIN is read from [PinStorageService] (flutter_secure_storage)
  /// and passed directly to the native layer — never logged or cached locally.
  Future<bool> wakeAndUnlock() async {
    try {
      final pin = await _pinStorage.getPin();
      if (pin == null || pin.isEmpty) return false;

      final result = await _channel.invokeMethod<Map>('wakeAndUnlock', {
        'pin': pin,
      });
      return result?['success'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Locks the device (turns the screen off and activates the keyguard).
  Future<bool> lockDevice() async {
    try {
      final result =
          await _channel.invokeMethod<Map>('lockDevice');
      return result?['success'] == true;
    } catch (_) {
      return false;
    }
  }

  // ── State queries ──────────────────────────────────────────────────────

  /// Whether the screen is currently on.
  Future<bool> isScreenOn() async {
    try {
      return await _channel.invokeMethod<bool>('isScreenOn') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether the device is currently showing the keyguard (locked).
  Future<bool> isDeviceLocked() async {
    try {
      return await _channel.invokeMethod<bool>('isDeviceLocked') ?? false;
    } catch (_) {
      return false;
    }
  }
}
