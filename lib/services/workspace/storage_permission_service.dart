import '../permission/permission_manager.dart';

/// Handles storage permission checks and requests for the workspace.
///
/// Delegates to [PermissionManager] which handles the API-level fallback
/// between [Permission.manageExternalStorage] (API 30+) and
/// [Permission.storage] (older).
class StoragePermissionService {
  StoragePermissionService._();
  static final StoragePermissionService instance = StoragePermissionService._();

  final PermissionManager _manager = PermissionManager();

  /// Check if storage permission is currently granted.
  Future<bool> isGranted() async {
    return _manager.isGranted(PermissionType.storage);
  }

  /// Request storage permission. Returns true if granted.
  Future<bool> request() async {
    final result = await _manager.request(PermissionType.storage);
    if (result == PermissionResult.granted) return true;
    await openSettings();
    return false;
  }

  /// Open the app's settings page (for when user permanently denied).
  Future<void> openSettings() async {
    await _manager.openSettings(PermissionType.storage);
  }
}