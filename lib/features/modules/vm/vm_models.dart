enum VmRuntimeStatus {
  unavailable,
  notInstalled,
  downloading,
  installed,
  starting,
  running,
  stopped,
  error,
}

extension VmRuntimeStatusX on VmRuntimeStatus {
  String get wireName => switch (this) {
    VmRuntimeStatus.unavailable => 'unavailable',
    VmRuntimeStatus.notInstalled => 'not_installed',
    VmRuntimeStatus.downloading => 'downloading',
    VmRuntimeStatus.installed => 'installed',
    VmRuntimeStatus.starting => 'starting',
    VmRuntimeStatus.running => 'running',
    VmRuntimeStatus.stopped => 'stopped',
    VmRuntimeStatus.error => 'error',
  };

  static VmRuntimeStatus fromWireName(String? value) => switch (value) {
    'not_installed' => VmRuntimeStatus.notInstalled,
    'downloading' => VmRuntimeStatus.downloading,
    'installed' => VmRuntimeStatus.installed,
    'starting' => VmRuntimeStatus.starting,
    'running' => VmRuntimeStatus.running,
    'stopped' => VmRuntimeStatus.stopped,
    'error' => VmRuntimeStatus.error,
    _ => VmRuntimeStatus.unavailable,
  };
}

enum VmPluginStatus {
  unknown,
  notInstalled,
  installing,
  installed,
  error,
}

extension VmPluginStatusX on VmPluginStatus {
  String get wireName => switch (this) {
    VmPluginStatus.unknown => 'unknown',
    VmPluginStatus.notInstalled => 'not_installed',
    VmPluginStatus.installing => 'installing',
    VmPluginStatus.installed => 'installed',
    VmPluginStatus.error => 'error',
  };

  static VmPluginStatus fromWireName(String? value) => switch (value) {
    'not_installed' => VmPluginStatus.notInstalled,
    'installing' => VmPluginStatus.installing,
    'installed' => VmPluginStatus.installed,
    'error' => VmPluginStatus.error,
    _ => VmPluginStatus.unknown,
  };
}

/// Per-plugin install state tracked locally and reported to the agent via
/// `vm.list_plugins`.
class VmPluginState {
  const VmPluginState({
    required this.pluginId,
    required this.status,
    this.version = '',
    this.message = '',
  });

  factory VmPluginState.fromJson(Map<String, dynamic> json) {
    return VmPluginState(
      pluginId: json['plugin_id'] as String? ?? '',
      status: VmPluginStatusX.fromWireName(json['status'] as String?),
      version: json['version'] as String? ?? '',
      message: json['message'] as String? ?? '',
    );
  }

  final String pluginId;
  final VmPluginStatus status;
  final String version;
  final String message;

  Map<String, dynamic> toJson() => {
    'plugin_id': pluginId,
    'status': status.wireName,
    if (version.isNotEmpty) 'version': version,
    if (message.isNotEmpty) 'message': message,
  };

  VmPluginState copyWith({
    VmPluginStatus? status,
    String? version,
    String? message,
  }) {
    return VmPluginState(
      pluginId: pluginId,
      status: status ?? this.status,
      version: version ?? this.version,
      message: message ?? this.message,
    );
  }
}

class VmRuntimeSnapshot {
  const VmRuntimeSnapshot({
    required this.status,
    required this.nativeRuntimeAvailable,
    this.rootfsInstalled = false,
    this.serviceRunning = false,
    this.port,
    this.runtimeVersion = '',
    this.rootfsPath = '',
    this.workspacePath = '',
    this.message = '',
    this.updatedAt,
  });

  factory VmRuntimeSnapshot.unavailable({String message = ''}) {
    return VmRuntimeSnapshot(
      status: VmRuntimeStatus.unavailable,
      nativeRuntimeAvailable: false,
      message: message,
      updatedAt: DateTime.now(),
    );
  }

  factory VmRuntimeSnapshot.fromJson(Map<String, dynamic> json) {
    return VmRuntimeSnapshot(
      status: VmRuntimeStatusX.fromWireName(json['status'] as String?),
      nativeRuntimeAvailable: json['native_runtime_available'] as bool? ?? true,
      rootfsInstalled: json['rootfs_installed'] as bool? ?? false,
      serviceRunning: json['service_running'] as bool? ?? false,
      port: json['port'] as int?,
      runtimeVersion: json['runtime_version'] as String? ?? '',
      rootfsPath: json['rootfs_path'] as String? ?? '',
      workspacePath: json['workspace_path'] as String? ?? '',
      message: json['message'] as String? ?? '',
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }

  final VmRuntimeStatus status;
  final bool nativeRuntimeAvailable;
  final bool rootfsInstalled;
  final bool serviceRunning;
  final int? port;
  final String runtimeVersion;
  final String rootfsPath;
  final String workspacePath;
  final String message;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
    'status': status.wireName,
    'native_runtime_available': nativeRuntimeAvailable,
    'rootfs_installed': rootfsInstalled,
    'service_running': serviceRunning,
    if (port != null) 'port': port,
    'runtime_version': runtimeVersion,
    'rootfs_path': rootfsPath,
    'workspace_path': workspacePath,
    'message': message,
    if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
  };

  VmRuntimeSnapshot copyWith({
    VmRuntimeStatus? status,
    bool? nativeRuntimeAvailable,
    bool? rootfsInstalled,
    bool? serviceRunning,
    int? port,
    String? runtimeVersion,
    String? rootfsPath,
    String? workspacePath,
    String? message,
    DateTime? updatedAt,
  }) {
    return VmRuntimeSnapshot(
      status: status ?? this.status,
      nativeRuntimeAvailable:
          nativeRuntimeAvailable ?? this.nativeRuntimeAvailable,
      rootfsInstalled: rootfsInstalled ?? this.rootfsInstalled,
      serviceRunning: serviceRunning ?? this.serviceRunning,
      port: port ?? this.port,
      runtimeVersion: runtimeVersion ?? this.runtimeVersion,
      rootfsPath: rootfsPath ?? this.rootfsPath,
      workspacePath: workspacePath ?? this.workspacePath,
      message: message ?? this.message,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Result of running a single shell command in the VM runtime.
class VmCommandResult {
  const VmCommandResult({
    required this.success,
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.message = '',
  });

  factory VmCommandResult.fromJson(Map<String, dynamic> json) {
    return VmCommandResult(
      success: json['success'] as bool? ?? false,
      exitCode: json['exit_code'] as int? ?? -1,
      stdout: json['stdout'] as String? ?? '',
      stderr: json['stderr'] as String? ?? '',
      message: json['message'] as String? ?? '',
    );
  }

  factory VmCommandResult.unavailable(String message) {
    return VmCommandResult(
      success: false,
      exitCode: -1,
      message: message,
    );
  }

  final bool success;
  final int exitCode;
  final String stdout;
  final String stderr;
  final String message;

  Map<String, dynamic> toJson() => {
    'success': success,
    'exit_code': exitCode,
    if (stdout.isNotEmpty) 'stdout': stdout,
    if (stderr.isNotEmpty) 'stderr': stderr,
    if (message.isNotEmpty) 'message': message,
  };
}
