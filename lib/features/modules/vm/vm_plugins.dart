import 'package:flutter/material.dart';

/// A user-installable runtime plugin (language toolchain or CLI tool) inside
/// the VM runtime.
///
/// Per AGENTS.md (#1 accuracy, #7 generic entity matching), the agent never
/// invents plugin ids. The agent calls `vm.list_plugins` to see what is
/// available + installed, then asks the user to install missing ones via
/// the VM Runtime screen.
@immutable
class VmPlugin {
  const VmPlugin({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.accent,
    required this.installCommand,
    required this.versionCommand,
    this.estimatedSizeMb = 0,
    this.tags = const [],
  });

  /// Stable identifier (e.g. `python`, `node`, `git`).
  final String id;

  /// Display name (e.g. `Python 3`, `Node.js`).
  final String name;

  /// One-line description shown in the UI.
  final String description;

  final IconData icon;
  final Color accent;

  /// Shell command the runtime executes to install the plugin.
  /// Run as root inside the proot session. Idempotent (safe to re-run).
  final String installCommand;

  /// Probe command to detect if the plugin is installed and report version.
  /// A non-zero exit code means "not installed".
  final String versionCommand;

  /// Approximate download size, displayed before install.
  final int estimatedSizeMb;

  /// Capability tags exposed to the agent for `vm.list_plugins` so it can
  /// decide if the plugin satisfies the user's request.
  /// Examples: `['javascript', 'web', 'frontend']`.
  final List<String> tags;
}

/// Curated plugin catalog. Generic-by-design (AGENTS.md #2): no hardcoded
/// per-language UX in the engine — the agent reasons about tags + name.
class VmPluginCatalog {
  const VmPluginCatalog._();

  static const git = VmPlugin(
    id: 'git',
    name: 'Git',
    description: 'Version control. Clone, commit, branch, and push.',
    icon: Icons.commit_rounded,
    accent: Color(0xFFF97316),
    installCommand: 'apt-get update && apt-get install -y git',
    versionCommand: 'git --version',
    estimatedSizeMb: 30,
    tags: ['git', 'version-control', 'clone', 'github'],
  );

  static const python = VmPlugin(
    id: 'python',
    name: 'Python 3',
    description: 'Python 3 + pip for scripting, data, and backend.',
    icon: Icons.code_rounded,
    accent: Color(0xFF3B82F6),
    installCommand:
        'apt-get update && apt-get install -y python3 python3-pip',
    versionCommand: 'python3 --version',
    estimatedSizeMb: 45,
    tags: ['python', 'scripting', 'backend', 'data', 'pip'],
  );

  static const node = VmPlugin(
    id: 'node',
    name: 'Node.js 20',
    description: 'Node.js 20 + npm. Modern enough for Vite, Next, and friends.',
    icon: Icons.javascript_rounded,
    accent: Color(0xFF10B981),
    // Ubuntu 22.04's apt nodejs is Node 12 (too old for Vite). Pull the
    // NodeSource v20 repo first, then install. Idempotent.
    installCommand:
        'apt-get update && '
        'apt-get install -y curl ca-certificates gnupg && '
        'curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && '
        'apt-get install -y nodejs',
    versionCommand: 'node --version',
    estimatedSizeMb: 110,
    tags: ['node', 'javascript', 'npm', 'web', 'frontend', 'vite', 'backend'],
  );

  static const bun = VmPlugin(
    id: 'bun',
    name: 'Bun',
    description: 'Fast JavaScript runtime, alternative to Node.',
    icon: Icons.flash_on_rounded,
    accent: Color(0xFFFBBF24),
    installCommand:
        'apt-get update && apt-get install -y unzip curl && '
        'curl -fsSL https://bun.sh/install | bash && '
        'ln -sf "\$HOME/.bun/bin/bun" /usr/local/bin/bun',
    versionCommand: 'bun --version',
    estimatedSizeMb: 60,
    tags: ['bun', 'javascript', 'runtime', 'web', 'fast'],
  );

  static const go = VmPlugin(
    id: 'go',
    name: 'Go',
    description: 'Go toolchain for backend services and CLIs.',
    icon: Icons.terminal_rounded,
    accent: Color(0xFF06B6D4),
    installCommand: 'apt-get update && apt-get install -y golang-go',
    versionCommand: 'go version',
    estimatedSizeMb: 200,
    tags: ['go', 'golang', 'backend', 'cli'],
  );

  static const rust = VmPlugin(
    id: 'rust',
    name: 'Rust',
    description: 'Rust toolchain via rustup. Cargo included.',
    icon: Icons.settings_rounded,
    accent: Color(0xFFB45309),
    installCommand:
        "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | "
        'sh -s -- -y --default-toolchain stable && '
        'ln -sf "\$HOME/.cargo/bin/cargo" /usr/local/bin/cargo && '
        'ln -sf "\$HOME/.cargo/bin/rustc" /usr/local/bin/rustc',
    versionCommand: 'rustc --version',
    estimatedSizeMb: 250,
    tags: ['rust', 'cargo', 'systems', 'cli'],
  );

  static const buildEssential = VmPlugin(
    id: 'build_essential',
    name: 'Build Essentials',
    description: 'gcc, make, and friends. Required by many other tools.',
    icon: Icons.construction_rounded,
    accent: Color(0xFF64748B),
    installCommand:
        'apt-get update && apt-get install -y build-essential',
    versionCommand: 'gcc --version',
    estimatedSizeMb: 180,
    tags: ['gcc', 'make', 'build', 'compiler', 'native'],
  );

  /// Order matters for UI: most useful for agent-driven web building first.
  static const List<VmPlugin> available = [
    git,
    node,
    python,
    bun,
    go,
    rust,
    buildEssential,
  ];

  static VmPlugin? byId(String id) {
    for (final p in available) {
      if (p.id == id) return p;
    }
    return null;
  }
}
