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
    this.runtimeBinariesInstalled = false,
    this.rootfsInstalled = false,
    this.serviceRunning = false,
    this.port,
    this.runtimeVersion = '',
    this.runtimeBinaryPath = '',
    this.rootfsPath = '',
    this.workspacePath = '',
    this.vmWorkingDir = '',
    this.agentFilesDir = '',
    this.agentFilesAvailable = false,
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
      runtimeBinariesInstalled:
          json['runtime_binaries_installed'] as bool? ?? false,
      rootfsInstalled: json['rootfs_installed'] as bool? ?? false,
      serviceRunning: json['service_running'] as bool? ?? false,
      port: json['port'] as int?,
      runtimeVersion: json['runtime_version'] as String? ?? '',
      runtimeBinaryPath: json['runtime_binary_path'] as String? ?? '',
      rootfsPath: json['rootfs_path'] as String? ?? '',
      workspacePath: json['workspace_path'] as String? ?? '',
      vmWorkingDir: json['vm_working_dir'] as String? ?? '',
      agentFilesDir: json['agent_files_dir'] as String? ?? '',
      agentFilesAvailable: json['agent_files_available'] as bool? ?? false,
      message: json['message'] as String? ?? '',
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }

  final VmRuntimeStatus status;
  final bool nativeRuntimeAvailable;
  final bool runtimeBinariesInstalled;
  final bool rootfsInstalled;
  final bool serviceRunning;
  final int? port;
  final String runtimeVersion;
  final String runtimeBinaryPath;
  final String rootfsPath;
  final String workspacePath;

  /// In-guest path safe for builds/installs/git (internal ext4).
  final String vmWorkingDir;

  /// In-guest path where the agent's shared workspace files (from the files
  /// module) are mounted. Use this to read/serve files created via files.*.
  final String agentFilesDir;

  /// Whether the shared agent-files dir exists and is mounted into the VM.
  final bool agentFilesAvailable;

  final String message;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
    'status': status.wireName,
    'native_runtime_available': nativeRuntimeAvailable,
    'runtime_binaries_installed': runtimeBinariesInstalled,
    'rootfs_installed': rootfsInstalled,
    'service_running': serviceRunning,
    if (port != null) 'port': port,
    'runtime_version': runtimeVersion,
    'runtime_binary_path': runtimeBinaryPath,
    'rootfs_path': rootfsPath,
    'workspace_path': workspacePath,
    if (vmWorkingDir.isNotEmpty) 'vm_working_dir': vmWorkingDir,
    if (agentFilesDir.isNotEmpty) 'agent_files_dir': agentFilesDir,
    'agent_files_available': agentFilesAvailable,
    'message': message,
    if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
  };

  VmRuntimeSnapshot copyWith({
    VmRuntimeStatus? status,
    bool? nativeRuntimeAvailable,
    bool? runtimeBinariesInstalled,
    bool? rootfsInstalled,
    bool? serviceRunning,
    int? port,
    String? runtimeVersion,
    String? runtimeBinaryPath,
    String? rootfsPath,
    String? workspacePath,
    String? vmWorkingDir,
    String? agentFilesDir,
    bool? agentFilesAvailable,
    String? message,
    DateTime? updatedAt,
  }) {
    return VmRuntimeSnapshot(
      status: status ?? this.status,
      nativeRuntimeAvailable:
          nativeRuntimeAvailable ?? this.nativeRuntimeAvailable,
      runtimeBinariesInstalled:
          runtimeBinariesInstalled ?? this.runtimeBinariesInstalled,
      rootfsInstalled: rootfsInstalled ?? this.rootfsInstalled,
      serviceRunning: serviceRunning ?? this.serviceRunning,
      port: port ?? this.port,
      runtimeVersion: runtimeVersion ?? this.runtimeVersion,
      runtimeBinaryPath: runtimeBinaryPath ?? this.runtimeBinaryPath,
      rootfsPath: rootfsPath ?? this.rootfsPath,
      workspacePath: workspacePath ?? this.workspacePath,
      vmWorkingDir: vmWorkingDir ?? this.vmWorkingDir,
      agentFilesDir: agentFilesDir ?? this.agentFilesDir,
      agentFilesAvailable: agentFilesAvailable ?? this.agentFilesAvailable,
      message: message ?? this.message,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class VmServerResult {
  const VmServerResult({
    required this.success,
    this.name = '',
    this.port = -1,
    this.pid,
    this.alive = false,
    this.listening = false,
    this.url = '',
    this.cwd = '',
    this.logPath = '',
    this.logTail = '',
    this.message = '',
    this.raw = const {},
  });

  factory VmServerResult.fromJson(Map<String, dynamic> json) => VmServerResult(
    success: json['success'] as bool? ?? false,
    name: json['name'] as String? ?? '',
    port: json['port'] as int? ?? -1,
    pid: json['pid'] as int?,
    alive: json['alive'] as bool? ?? false,
    listening: json['listening'] as bool? ?? false,
    url: json['url'] as String? ?? '',
    cwd: json['cwd'] as String? ?? '',
    logPath: json['log_path'] as String? ?? '',
    logTail: json['log_tail'] as String? ?? '',
    message: json['message'] as String? ?? '',
    raw: json,
  );

  factory VmServerResult.unavailable(String message) => VmServerResult(
    success: false,
    message: message,
  );

  final bool success;
  final String name;
  final int port;
  final int? pid;
  final bool alive;
  final bool listening;
  final String url;
  final String cwd;
  final String logPath;
  final String logTail;
  final String message;
  final Map<String, dynamic> raw;

  Map<String, dynamic> toJson() => {
    ...raw,
    'success': success,
    if (name.isNotEmpty) 'name': name,
    if (port > 0) 'port': port,
    if (pid != null) 'pid': pid,
    'alive': alive,
    'listening': listening,
    if (url.isNotEmpty) 'url': url,
    if (cwd.isNotEmpty) 'cwd': cwd,
    if (logPath.isNotEmpty) 'log_path': logPath,
    if (logTail.isNotEmpty) 'log_tail': logTail,
    if (message.isNotEmpty) 'message': message,
  };
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
