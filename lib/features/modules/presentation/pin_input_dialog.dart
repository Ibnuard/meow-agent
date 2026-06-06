import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../settings/data/app_language_provider.dart';
import '../data/pin_storage_service.dart';

/// Dialog for entering and storing device PIN for Shizuku keyguard operations.
class PinInputDialog extends StatefulWidget {
  const PinInputDialog({super.key, required this.strings});

  final AppStrings strings;

  static Future<String?> show(BuildContext context, AppStrings strings) {
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => PinInputDialog(strings: strings),
    );
  }

  @override
  State<PinInputDialog> createState() => _PinInputDialogState();
}

class _PinInputDialogState extends State<PinInputDialog> {
  final _pinController = TextEditingController();
  final _existingPinController = TextEditingController();
  final _pinStorage = PinStorageService.instance;

  bool _hasExistingPin = false;
  bool _isLoading = true;
  bool _isVerifying = false;
  bool _showExistingPinInput = false;
  bool _verified = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkExistingPin();
  }

  Future<void> _checkExistingPin() async {
    final hasPin = await _pinStorage.hasPin();
    if (mounted) {
      setState(() {
        _hasExistingPin = hasPin;
        // Skip straight to verify when PIN already exists.
        _showExistingPinInput = hasPin;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    _existingPinController.dispose();
    super.dispose();
  }

  Future<void> _savePin() async {
    if (_pinController.text.isEmpty) {
      setState(() => _error = widget.strings.devicePinEmpty);
      return;
    }

    if (_pinController.text.length < 4) {
      setState(() => _error = widget.strings.devicePinMinLength);
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    await _pinStorage.savePin(_pinController.text);

    if (mounted) {
      Navigator.pop(context, _pinController.text);
    }
  }

  Future<void> _verifyAndEdit() async {
    if (_existingPinController.text.isEmpty) {
      setState(() => _error = widget.strings.devicePinVerifyRequired);
      return;
    }

    setState(() {
      _isVerifying = true;
      _error = null;
    });

    final storedPin = await _pinStorage.getPin();

    if (storedPin == _existingPinController.text) {
      if (mounted) {
        setState(() {
          _verified = true;
          _isVerifying = false;
          _pinController.clear();
          _error = null;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _error = widget.strings.devicePinMismatch;
          _isVerifying = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = widget.strings;

    return Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        padding: const EdgeInsets.all(24),
        constraints: const BoxConstraints(maxWidth: 400),
        child: _isLoading
            ? const SizedBox(
                height: 100,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  Text(
                    s.devicePinTitle,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Description
                  Text(
                    s.devicePinDescription,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Error message
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.error.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: cs.error.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline, size: 16, color: cs.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Existing PIN display (hidden during verify/edit flow)
                  if (_hasExistingPin && !_verified && !_showExistingPinInput) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: cs.primary.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 20,
                            color: cs.primary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              s.devicePinEncrypted,
                              style: TextStyle(
                                fontSize: 14,
                                color: cs.onSurface,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () {
                              setState(() {
                                _showExistingPinInput = true;
                                _error = null;
                              });
                            },
                            icon: const Icon(Icons.edit_outlined, size: 16),
                            label: Text(s.devicePinEdit),
                            style: TextButton.styleFrom(
                              foregroundColor: cs.primary,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Step 1: Verify existing PIN
                  if (_showExistingPinInput && !_verified) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: cs.primary.withValues(alpha: 0.15),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.devicePinVerifyTitle,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            s.devicePinVerifyHint,
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _existingPinController,
                            obscureText: true,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            style: TextStyle(color: cs.onSurface),
                            decoration: InputDecoration(
                              hintText: '••••••',
                              hintStyle: TextStyle(color: cs.onSurfaceVariant),
                              filled: true,
                              fillColor: cs.surfaceContainerHighest
                                  .withValues(alpha: 0.3),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: cs.outline.withValues(alpha: 0.3),
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: cs.outline.withValues(alpha: 0.3),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(color: cs.primary),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    _showExistingPinInput = false;
                                    _existingPinController.clear();
                                    _error = null;
                                  });
                                },
                                child: Text(s.devicePinCancel),
                              ),
                              const Spacer(),
                              FilledButton.icon(
                                onPressed:
                                    _isVerifying ? null : _verifyAndEdit,
                                icon: _isVerifying
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.check, size: 16),
                                label: Text(s.devicePinVerifyButton),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Step 2: New PIN input (first time OR after verification)
                  if (!_hasExistingPin || _verified) ...[
                    Text(
                      _verified ? s.devicePinNewTitle : s.devicePinTitle,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _pinController,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: TextStyle(color: cs.onSurface),
                      decoration: InputDecoration(
                        hintText: s.devicePinInputHint,
                        hintStyle: TextStyle(color: cs.onSurfaceVariant),
                        filled: true,
                        fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.3),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: cs.outline.withValues(alpha: 0.3),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: cs.outline.withValues(alpha: 0.3),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: cs.primary),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Action buttons
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(s.devicePinCancel),
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: _savePin,
                          icon: const Icon(Icons.save_outlined, size: 16),
                          label: Text(s.devicePinSave),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
