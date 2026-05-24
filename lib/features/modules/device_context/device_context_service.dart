import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_context_models.dart';

/// Flutter-side wrapper for the native DeviceContextPlugin MethodChannel.
class DeviceContextService {
  static const _channel = MethodChannel('com.meowagent/device_context');

  Future<BatteryInfo?> getBatteryInfo() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getBatteryInfo');
      if (raw == null) return null;
      return BatteryInfo.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<NetworkInfo?> getNetworkInfo() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getNetworkInfo');
      if (raw == null) return null;
      return NetworkInfo.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<StorageInfo?> getStorageInfo() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getStorageInfo');
      if (raw == null) return null;
      return StorageInfo.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<TimeInfo?> getTimeInfo() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getTimeInfo');
      if (raw == null) return null;
      return TimeInfo.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<LocaleInfo?> getLocaleInfo() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getLocaleInfo');
      if (raw == null) return null;
      return LocaleInfo.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<ForegroundAppInfo?> getForegroundAppInfo() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getForegroundAppInfo');
      if (raw == null) return null;
      return ForegroundAppInfo.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getUsageStats({int days = 7}) async {
    try {
      final raw = await _channel.invokeMethod<Map>(
        'getUsageStats',
        {'days': days},
      );
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getDeviceSummary() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getDeviceSummary');
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw.map((k, v) {
        if (v is Map) return MapEntry(k.toString(), Map<String, dynamic>.from(v));
        if (v is List) {
          return MapEntry(k.toString(), v.map((e) {
            if (e is Map) return Map<String, dynamic>.from(e);
            return e;
          }).toList());
        }
        return MapEntry(k.toString(), v);
      }));
    } on PlatformException {
      return null;
    }
  }

  Future<ChargingInfo?> getChargingInfo() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getChargingInfo');
      if (raw == null) return null;
      return ChargingInfo.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<DndInfo?> getDndInfo() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getDndInfo');
      if (raw == null) return null;
      return DndInfo.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<BluetoothInfo?> getBluetoothInfo() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getBluetoothInfo');
      if (raw == null) return null;
      return BluetoothInfo.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<Map<String, dynamic>?> setDndMode({
    required bool enabled,
    String? mode,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map>('setDndMode', {
        'enabled': enabled,
        'mode': mode,
      });
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<Map<String, dynamic>?> reconnectWifi() async {
    try {
      final raw = await _channel.invokeMethod<Map>('reconnectWifi');
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<Map<String, dynamic>?> setBluetoothEnabled({required bool enabled}) async {
    try {
      final raw = await _channel.invokeMethod<Map>('setBluetoothEnabled', {
        'enabled': enabled,
      });
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getWifiStatus() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getWifiStatus');
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw);
    } on PlatformException {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getCellularStatus() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getCellularStatus');
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw);
    } on PlatformException {
      return null;
    }
  }
}

final deviceContextServiceProvider = Provider<DeviceContextService>(
  (ref) => DeviceContextService(),
);
