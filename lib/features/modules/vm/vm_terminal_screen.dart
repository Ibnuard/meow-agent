import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../settings/data/app_language_provider.dart';
import 'vm_runtime_service.dart';

/// Terminal screen for the VM runtime.
///
/// Per-command REPL (not a persistent PTY) because our native side spawns
/// proot fresh each invocation. To make `cd`, env, and similar stateful
/// commands feel right, we track CWD client-side and prefix each command
/// with `cd <cwd> && ` so the user perceives a continuous session.
///
/// Limits intentionally NOT enforced here:
///   - Long-running interactive programs (vim, top, npm dev server) won't
///     work — they need a real PTY. The agent uses non-interactive commands
///     anyway; this screen is for `ls`, `cat`, `apt`, `pip`, etc.
class VmTerminalScreen extends ConsumerStatefulWidget {
  const VmTerminalScreen({super.key});

  @override
  ConsumerState<VmTerminalScreen> createState() => _VmTerminalScreenState();
}

class _TerminalEntry {
  _TerminalEntry({
    required this.cwd,
    required this.command,
    this.stdout = '',
    this.exitCode,
    this.running = false,
  });

  final String cwd;
  final String command;
  String stdout;
  String stderr = '';
  int? exitCode;
  bool running;
}

class _VmTerminalScreenState extends ConsumerState<VmTerminalScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scrollController = ScrollController();
  final _entries = <_TerminalEntry>[];
  final _history = <String>[];
  int _historyIndex = -1;
  String _cwd = '/root/workspace';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Friendly intro entry so the screen doesn't feel empty.
    _entries.add(
      _TerminalEntry(
        cwd: _cwd,
        command: '',
        stdout: 'Welcome. Type any shell command and press Run.\n'
            'cd persists across commands. Try: uname -a',
        exitCode: 0,
      ),
    );
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _runCurrent() async {
    final command = _input.text.trim();
    if (command.isEmpty || _busy) return;

    _input.clear();
    _history.add(command);
    _historyIndex = _history.length;

    final entry = _TerminalEntry(cwd: _cwd, command: command, running: true);
    setState(() {
      _entries.add(entry);
      _busy = true;
    });
    _scrollToBottom();

    // Wrap the user command so cwd persists. After execution, capture the
    // resulting cwd so subsequent commands resume there.
    final wrapped =
        'cd ${_shellQuote(_cwd)} && $command\n'
        '__exit=\$?\n'
        'printf "\\n__MEOW_PWD__:%s" "\$(pwd)"\n'
        'exit \$__exit';

    final result = await ref
        .read(vmRuntimeServiceProvider)
        .runCommand(wrapped, timeoutMs: 120000);

    var stdout = result.stdout;
    final pwdMarker = stdout.lastIndexOf('__MEOW_PWD__:');
    if (pwdMarker >= 0) {
      final newCwd = stdout.substring(pwdMarker + '__MEOW_PWD__:'.length).trim();
      if (newCwd.isNotEmpty) _cwd = newCwd;
      stdout = stdout.substring(0, pwdMarker).trimRight();
    }

    if (!mounted) return;
    setState(() {
      entry.stdout = stdout;
      entry.stderr = result.stderr;
      entry.exitCode = result.exitCode;
      entry.running = false;
      _busy = false;
    });
    _scrollToBottom();
    _focus.requestFocus();
  }

  String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _navigateHistory(int delta) {
    if (_history.isEmpty) return;
    final next = (_historyIndex + delta).clamp(0, _history.length);
    if (next == _history.length) {
      _input.text = '';
    } else {
      _input.text = _history[next];
      _input.selection = TextSelection.fromPosition(
        TextPosition(offset: _input.text.length),
      );
    }
    setState(() => _historyIndex = next);
  }

  void _clear() {
    setState(() {
      _entries.clear();
      _entries.add(
        _TerminalEntry(
          cwd: _cwd,
          command: '',
          stdout: 'Cleared. cwd: $_cwd',
          exitCode: 0,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final s = AppStrings(resolveLanguageCode(ref.watch(appLanguageProvider)));

    return Scaffold(
      backgroundColor: const Color(0xFF0B1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1020),
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
        title: Text(s.vmTerminalTitle),
        actions: [
          IconButton(
            tooltip: s.vmTerminalClear,
            color: Colors.white,
            onPressed: _clear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                itemCount: _entries.length,
                itemBuilder: (_, i) => _EntryView(entry: _entries[i]),
              ),
            ),
            _PromptBar(
              cwd: _cwd,
              controller: _input,
              focusNode: _focus,
              onSubmit: _runCurrent,
              onHistoryUp: () => _navigateHistory(-1),
              onHistoryDown: () => _navigateHistory(1),
              busy: _busy,
              s: s,
              isDark: isDark,
              cs: cs,
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryView extends StatelessWidget {
  const _EntryView({required this.entry});

  final _TerminalEntry entry;

  static const _mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12.5,
    height: 1.35,
    color: Color(0xFFD9DEE6),
  );

  @override
  Widget build(BuildContext context) {
    final hasCommand = entry.command.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasCommand)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF111A2E),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: RichText(
                text: TextSpan(
                  style: _mono,
                  children: [
                    TextSpan(
                      text: '${_truncCwd(entry.cwd)} ',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        color: Color(0xFF7DD3FC),
                      ),
                    ),
                    const TextSpan(
                      text: '\$ ',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        color: Color(0xFF34D399),
                      ),
                    ),
                    TextSpan(text: entry.command),
                  ],
                ),
              ),
            ),
          if (entry.running) ...[
            const SizedBox(height: 6),
            Row(
              children: const [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: Color(0xFF7DD3FC),
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  'running...',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Color(0xFF94A3B8),
                  ),
                ),
              ],
            ),
          ],
          if (entry.stdout.isNotEmpty) ...[
            const SizedBox(height: 6),
            SelectableText(entry.stdout, style: _mono),
          ],
          if (entry.stderr.isNotEmpty) ...[
            const SizedBox(height: 6),
            SelectableText(
              entry.stderr,
              style: _mono.copyWith(color: const Color(0xFFFCA5A5)),
            ),
          ],
          if (!entry.running &&
              entry.exitCode != null &&
              entry.exitCode != 0 &&
              hasCommand) ...[
            const SizedBox(height: 4),
            Text(
              'exit ${entry.exitCode}',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Color(0xFFFCA5A5),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _truncCwd(String cwd) {
    if (cwd.length <= 24) return cwd;
    return '...${cwd.substring(cwd.length - 21)}';
  }
}

class _PromptBar extends StatelessWidget {
  const _PromptBar({
    required this.cwd,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    required this.onHistoryUp,
    required this.onHistoryDown,
    required this.busy,
    required this.s,
    required this.isDark,
    required this.cs,
  });

  final String cwd;
  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function() onSubmit;
  final VoidCallback onHistoryUp;
  final VoidCallback onHistoryDown;
  final bool busy;
  final AppStrings s;
  final bool isDark;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF0B1020),
        border: Border(top: BorderSide(color: Color(0xFF1B2540))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              cwd,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Color(0xFF7DD3FC),
              ),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: KeyboardListener(
                  focusNode: FocusNode(),
                  onKeyEvent: (event) {
                    if (event is! KeyDownEvent) return;
                    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                      onHistoryUp();
                    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                      onHistoryDown();
                    }
                  },
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: true,
                    enabled: !busy,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: Color(0xFFD9DEE6),
                    ),
                    minLines: 1,
                    maxLines: 4,
                    cursorColor: const Color(0xFF7DD3FC),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSubmit(),
                    decoration: InputDecoration(
                      hintText: busy ? '...' : s.vmTerminalHint,
                      hintStyle: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: Color(0xFF64748B),
                      ),
                      filled: true,
                      fillColor: const Color(0xFF111A2E),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFF1B2540)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: Color(0xFF3B82F6),
                          width: 1.4,
                        ),
                      ),
                      disabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFF1B2540)),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Material(
                color: const Color(0xFF3B82F6),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: busy ? null : onSubmit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    child: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
