import 'package:flutter/material.dart';

import '../../settings/data/app_language_provider.dart';

/// Represents the current status of Shizuku integration.
class ShizukuStatus {
  const ShizukuStatus({
    this.available = false,
    this.permissionGranted = false,
    this.requestPending = false,
    this.error,
  });

  const ShizukuStatus.unknown()
      : available = false,
        permissionGranted = false,
        requestPending = false,
        error = null;

  final bool available;
  final bool permissionGranted;
  final bool requestPending;
  final String? error;

  bool get isReady => available && permissionGranted && !requestPending;

  IconData get icon {
    if (requestPending) return Icons.sync_rounded;
    if (error != null) return Icons.error_outline_rounded;
    if (isReady) return Icons.check_circle_outline_rounded;
    if (available) return Icons.warning_amber_rounded;
    return Icons.help_outline_rounded;
  }

  Color get color {
    if (requestPending) return Colors.orange;
    if (error != null) return Colors.red;
    if (isReady) return Colors.green;
    if (available) return Colors.orange;
    return Colors.grey;
  }

  String message(AppStrings s) {
    if (requestPending) return s.shizukuStatusRequestPending;
    if (error != null) return s.shizukuStatusError(error!);
    if (isReady) return s.shizukuStatusReady;
    if (available) return s.shizukuStatusPermissionNeeded;
    return s.shizukuStatusUnavailable;
  }
}
