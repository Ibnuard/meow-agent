import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Handles storage permission checks and requests for the workspace.
///
/// On Android 11+ (API 30+), [Permission.manageExternalStorage] is required
/// to read/write files in `/Documents/MeowAgent/`. On older versions,
/// [Permission.storage] is sufficient.
class StoragePermissionService {
  StoragePermissionService._();
  static final StoragePermissionService instance = StoragePermissionService._();

  /// Check if storage permission is currently granted.
  Future<bool> isGranted() async {
    if (!Platform.isAndroid) return true;
    final status = await Permission.manageExternalStorage.status;
    return status.isGranted;
  }

  /// Request storage permission. Returns true if granted.
  Future<bool> request() async {
    if (!Platform.isAndroid) return true;
    final status = await Permission.manageExternalStorage.request();
    return status.isGranted;
  }

  /// Open the app's settings page (for when user permanently denied).
  Future<void> openSettings() async {
    await openAppSettings();
  }
}
