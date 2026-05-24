/// Battery status from device.battery tool.
class BatteryInfo {
  const BatteryInfo({
    required this.level,
    required this.isCharging,
    required this.chargingStatus,
    required this.batterySaver,
  });

  final int level;
  final bool isCharging;
  final String chargingStatus; // 'charging' | 'discharging' | 'full' | 'unknown'
  final bool batterySaver;

  Map<String, dynamic> toJson() => {
        'level': level,
        'isCharging': isCharging,
        'chargingStatus': chargingStatus,
        'batterySaver': batterySaver,
      };

  factory BatteryInfo.fromMap(Map<dynamic, dynamic> m) => BatteryInfo(
        level: (m['level'] as num?)?.toInt() ?? 0,
        isCharging: m['isCharging'] as bool? ?? false,
        chargingStatus: m['chargingStatus'] as String? ?? 'unknown',
        batterySaver: m['batterySaver'] as bool? ?? false,
      );
}

/// Network status from device.network tool.
class NetworkInfo {
  const NetworkInfo({
    required this.isConnected,
    required this.type,
    this.wifiName,
    required this.isMetered,
  });

  final bool isConnected;
  final String type; // 'wifi' | 'cellular' | 'ethernet' | 'none'
  final String? wifiName;
  final bool isMetered;

  Map<String, dynamic> toJson() => {
        'isConnected': isConnected,
        'type': type,
        'wifiName': wifiName,
        'isMetered': isMetered,
      };

  factory NetworkInfo.fromMap(Map<dynamic, dynamic> m) => NetworkInfo(
        isConnected: m['isConnected'] as bool? ?? false,
        type: m['type'] as String? ?? 'none',
        wifiName: m['wifiName'] as String?,
        isMetered: m['isMetered'] as bool? ?? false,
      );
}

/// Storage info from device.storage tool.
class StorageInfo {
  const StorageInfo({
    required this.totalBytes,
    required this.freeBytes,
    required this.usedBytes,
    required this.usedPercent,
  });

  final int totalBytes;
  final int freeBytes;
  final int usedBytes;
  final int usedPercent;

  Map<String, dynamic> toJson() => {
        'totalBytes': totalBytes,
        'freeBytes': freeBytes,
        'usedBytes': usedBytes,
        'usedPercent': usedPercent,
      };

  factory StorageInfo.fromMap(Map<dynamic, dynamic> m) => StorageInfo(
        totalBytes: (m['totalBytes'] as num?)?.toInt() ?? 0,
        freeBytes: (m['freeBytes'] as num?)?.toInt() ?? 0,
        usedBytes: (m['usedBytes'] as num?)?.toInt() ?? 0,
        usedPercent: (m['usedPercent'] as num?)?.toInt() ?? 0,
      );
}

/// Time info from device.time tool.
class TimeInfo {
  const TimeInfo({
    required this.iso,
    required this.timezone,
    required this.epochMillis,
  });

  final String iso;
  final String timezone;
  final int epochMillis;

  Map<String, dynamic> toJson() => {
        'iso': iso,
        'timezone': timezone,
        'epochMillis': epochMillis,
      };

  factory TimeInfo.fromMap(Map<dynamic, dynamic> m) => TimeInfo(
        iso: m['iso'] as String? ?? '',
        timezone: m['timezone'] as String? ?? '',
        epochMillis: (m['epochMillis'] as num?)?.toInt() ?? 0,
      );
}

/// Locale info from device.locale tool.
class LocaleInfo {
  const LocaleInfo({
    required this.languageCode,
    required this.countryCode,
    required this.locale,
  });

  final String languageCode;
  final String countryCode;
  final String locale;

  Map<String, dynamic> toJson() => {
        'languageCode': languageCode,
        'countryCode': countryCode,
        'locale': locale,
      };

  factory LocaleInfo.fromMap(Map<dynamic, dynamic> m) => LocaleInfo(
        languageCode: m['languageCode'] as String? ?? '',
        countryCode: m['countryCode'] as String? ?? '',
        locale: m['locale'] as String? ?? '',
      );
}

/// Foreground app info from device.foreground_app tool.
class ForegroundAppInfo {
  const ForegroundAppInfo({
    required this.available,
    this.appName,
    this.packageName,
    this.reason,
  });

  final bool available;
  final String? appName;
  final String? packageName;
  final String? reason;

  Map<String, dynamic> toJson() => {
        'available': available,
        if (appName != null) 'appName': appName,
        if (packageName != null) 'packageName': packageName,
        if (reason != null) 'reason': reason,
      };

  factory ForegroundAppInfo.fromMap(Map<dynamic, dynamic> m) => ForegroundAppInfo(
        available: m['available'] as bool? ?? false,
        appName: m['appName'] as String?,
        packageName: m['packageName'] as String?,
        reason: m['reason'] as String?,
      );
}
