import 'package:flutter/material.dart';

import '../theme.dart';

/// A premium text input with external label and relaxed vertical rhythm.
///
/// Wraps [TextFormField] with:
/// - A floating label above the field (not inside).
/// - Soft translucent fill.
/// - Subtle border change on focus (no glow).
/// - Helper text below.
class MeowInput extends StatefulWidget {
const MeowInput({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.helper,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.validator,
    this.onChanged,
    this.onSubmitted,
    this.suffixIcon,
    this.maxLines = 1,
    this.autofocus = false,
    this.errorText,
    this.maxLength,
    this.textCapitalization,
    this.showCounter = false,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final String? helper;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffixIcon;
  final int maxLines;
  final bool autofocus;
  final String? errorText;
  final int? maxLength;
  final TextCapitalization? textCapitalization;
  final bool showCounter;

  @override
  State<MeowInput> createState() => _MeowInputState();
}

class _MeowInputState extends State<MeowInput> {
  final _focusNode = FocusNode();
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    setState(() => _hasFocus = _focusNode.hasFocus);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final theme = Theme.of(context);
    final errorStyle = theme.inputDecorationTheme.errorStyle ??
        TextStyle(fontSize: 12, color: theme.colorScheme.error);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // External label.
        if (widget.label != null) ...[
          Text(
            widget.label!,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: _hasFocus ? cs.primary : cs.onSurfaceVariant,
              letterSpacing: 0.1,
            ),
          ),
          const SizedBox(height: 8),
        ],

        // Text field — no outer glow, just the themed border states.
        TextFormField(
          controller: widget.controller,
          focusNode: _focusNode,
          obscureText: widget.obscureText,
          keyboardType: widget.keyboardType,
          textInputAction: widget.textInputAction,
          textCapitalization: widget.textCapitalization ?? TextCapitalization.none,
          maxLength: widget.maxLength,
          validator: widget.validator,
          onChanged: widget.onChanged,
          onFieldSubmitted: widget.onSubmitted,
          maxLines: widget.maxLines,
          autofocus: widget.autofocus,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: cs.onSurface,
            height: 1.4,
          ),
decoration: InputDecoration(
            hintText: widget.hint,
            suffixIcon: widget.suffixIcon,
            filled: true,
            fillColor: extras.inputFill,
            errorText: widget.errorText,
            errorMaxLines: 2,
            errorStyle: errorStyle,
            counter: widget.showCounter ? null : const SizedBox.shrink(),
          ),
        ),

        // Helper text.
        if (widget.helper != null) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              widget.helper!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: extras.subtleText,
                height: 1.4,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
