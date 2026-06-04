import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Test screen for Shizuku shell automation experiment.
/// Tests wake, unlock, input injection, and lock operations.
class ShizukuTestScreen extends StatefulWidget {
  const ShizukuTestScreen({super.key});

  @override
  State<ShizukuTestScreen> createState() =>
      _ShizukuTestScreenState();
}

class _ShizukuTestScreenState extends State<ShizukuTestScreen> {
  static const _channel = MethodChannel('com.meowagent/shizuku');

  String _status = 'Ready';
  Map<String, dynamic>? _result;
  bool _running = false;
  final _pinController = TextEditingController();

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _getStatus() async {
    try {
      final result = await _channel.invokeMethod('getStatus');
      setState(() {
        _result = Map<String, dynamic>.from(result as Map);
        final available = _result!['shizuku_available'] == true;
        final granted = _result!['permission_granted'] == true;
        _status = available
            ? (granted ? '✅ Shizuku ready' : '⚠️ Permission needed')
            : '❌ Shizuku not available';
      });
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _requestPermission() async {
    try {
      await _channel.invokeMethod('requestPermission');
      setState(() => _status = 'Permission requested — check Shizuku app');
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _execCommand(String command) async {
    setState(() {
      _running = true;
      _status = 'Executing: $command';
    });
    try {
      final result = await _channel.invokeMethod('exec', {'command': command});
      setState(() {
        _result = Map<String, dynamic>.from(result as Map);
        _status = _result!['success'] == true ? '✅ Success' : '❌ Failed';
        _running = false;
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
        _running = false;
      });
    }
  }

  Future<void> _wakeAndUnlock() async {
    final pin = _pinController.text.trim();
    setState(() {
      _running = true;
      _status = 'Waking and unlocking...';
      _result = null;
    });
    try {
      final result = await _channel.invokeMethod('wakeAndUnlock', {'pin': pin});
      setState(() {
        _result = Map<String, dynamic>.from(result as Map);
        _status = _result!['success'] == true
            ? '✅ Device unlocked!'
            : '❌ Unlock failed: ${_result!['error'] ?? 'unknown'}';
        _running = false;
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
        _running = false;
      });
    }
  }

  Future<void> _delayedWakeAndUnlock() async {
    final pin = _pinController.text.trim();
    if (pin.isEmpty) {
      setState(() => _status = '⚠️ Masukkan PIN dulu!');
      return;
    }

    setState(() {
      _running = true;
      _result = null;
    });

    // Countdown 10 seconds — user locks phone during this time
    for (var i = 10; i > 0; i--) {
      if (!mounted) return;
      setState(() => _status = '⏱️ Lock HP sekarang! Unlock dalam $i detik...');
      await Future.delayed(const Duration(seconds: 1));
    }

    if (!mounted) return;
    setState(() => _status = '🔓 Executing wake + unlock...');

    try {
      final result = await _channel.invokeMethod('wakeAndUnlock', {'pin': pin});
      if (!mounted) return;
      setState(() {
        _result = Map<String, dynamic>.from(result as Map);
        _status = _result!['success'] == true
            ? '✅ Device unlocked from locked state!'
            : '❌ Unlock failed: ${_result!['error'] ?? 'unknown'}';
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Error: $e';
        _running = false;
      });
    }
  }

  Future<void> _lockDevice() async {
    try {
      final result = await _channel.invokeMethod('lockDevice');
      setState(() {
        _result = Map<String, dynamic>.from(result as Map);
        _status = '🔒 Device locked';
      });
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020817),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text(
          'Shizuku Automation Test',
          style: TextStyle(color: Color(0xFFE5E7EB)),
        ),
        iconTheme: const IconThemeData(color: Color(0xFFE5E7EB)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.05),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Status',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _status,
                    style: TextStyle(
                      color: _status.contains('✅')
                          ? Colors.green
                          : _status.contains('❌')
                              ? Colors.red
                              : const Color(0xFFE5E7EB),
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Connection section
            _sectionLabel('CONNECTION'),
            const SizedBox(height: 10),
            _buildButton(
              label: 'Check Shizuku Status',
              icon: Icons.wifi_tethering_rounded,
              onTap: _getStatus,
              primary: true,
            ),
            const SizedBox(height: 10),
            _buildButton(
              label: 'Request Permission',
              icon: Icons.lock_open_rounded,
              onTap: _requestPermission,
            ),

            const SizedBox(height: 24),

            // Unlock section
            _sectionLabel('WAKE & UNLOCK'),
            const SizedBox(height: 10),
            // PIN input
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.05),
                ),
              ),
              child: TextField(
                controller: _pinController,
                style: const TextStyle(
                  color: Color(0xFFE5E7EB),
                  fontSize: 16,
                  letterSpacing: 4,
                ),
                keyboardType: TextInputType.number,
                obscureText: true,
                decoration: const InputDecoration(
                  hintText: 'Device PIN',
                  hintStyle: TextStyle(color: Color(0xFF64748B)),
                  border: InputBorder.none,
                  prefixIcon: Icon(Icons.pin_rounded, color: Color(0xFF64748B)),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _buildButton(
              label: 'Wake + Unlock (Full Sequence)',
              icon: Icons.phonelink_lock_rounded,
              onTap: _running ? null : _wakeAndUnlock,
              primary: true,
            ),
            const SizedBox(height: 10),
            _buildButton(
              label: '⏱️ Delayed Test (10s) — Lock HP setelah tap!',
              icon: Icons.timer_rounded,
              onTap: _running ? null : _delayedWakeAndUnlock,
              primary: true,
            ),
            const SizedBox(height: 10),
            _buildButton(
              label: 'Lock Device',
              icon: Icons.lock_rounded,
              onTap: _lockDevice,
            ),

            const SizedBox(height: 24),

            // Shell commands section
            _sectionLabel('SHELL COMMANDS'),
            const SizedBox(height: 10),
            _buildButton(
              label: 'Wake Screen (keyevent WAKEUP)',
              icon: Icons.brightness_high_rounded,
              onTap: () => _execCommand('input keyevent KEYCODE_WAKEUP'),
            ),
            const SizedBox(height: 8),
            _buildButton(
              label: 'Swipe Up (unlock gesture)',
              icon: Icons.swipe_up_rounded,
              onTap: () => _execCommand('input swipe 540 1800 540 800 300'),
            ),
            const SizedBox(height: 8),
            _buildButton(
              label: 'Check Screen State',
              icon: Icons.monitor_rounded,
              onTap: () => _execCommand("dumpsys power | grep 'Display Power'"),
            ),
            const SizedBox(height: 8),
            _buildButton(
              label: 'Check Keyguard',
              icon: Icons.security_rounded,
              onTap: () => _execCommand("dumpsys window | grep -E 'mDreamingLockscreen|isKeyguardShowing'"),
            ),

            // Result display
            if (_result != null) ...[
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A).withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Result',
                      style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                    ),
                    const SizedBox(height: 10),
                    SelectableText(
                      const JsonEncoder.withIndent('  ').convert(_result),
                      style: const TextStyle(
                        color: Color(0xFFE5E7EB),
                        fontSize: 11,
                        fontFamily: 'monospace',
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (_running)
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Center(
                  child: CircularProgressIndicator(color: Color(0xFF3B82F6)),
                ),
              ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: const Color(0xFF94A3B8).withValues(alpha: 0.7),
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildButton({
    required String label,
    required IconData icon,
    VoidCallback? onTap,
    bool primary = false,
  }) {
    return Material(
      color: primary
          ? const Color(0xFF3B82F6).withValues(alpha: 0.15)
          : const Color(0xFF0F172A).withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: primary
                  ? const Color(0xFF3B82F6).withValues(alpha: 0.3)
                  : Colors.white.withValues(alpha: 0.05),
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: primary
                    ? const Color(0xFF3B82F6)
                    : const Color(0xFF94A3B8),
                size: 20,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: onTap == null
                        ? const Color(0xFF64748B)
                        : const Color(0xFFE5E7EB),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: Color(0xFF64748B),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
