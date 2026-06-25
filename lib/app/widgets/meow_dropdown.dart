import 'package:flutter/material.dart';

import '../../features/settings/data/app_language_provider.dart';
import '../theme.dart';
import 'meow_sheet.dart';

enum MeowDropdownPresentation { sheet, menu }

class MeowDropdownOption<T> {
  const MeowDropdownOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.prefix,
    this.suffix,
    this.searchText,
    this.enabled = true,
  });

  final T value;
  final String label;
  final String? subtitle;
  final Widget? prefix;
  final Widget? suffix;
  final String? searchText;
  final bool enabled;

  String get searchableText =>
      [label, ?subtitle, ?searchText].join(' ').toLowerCase();
}

class _MeowDropdownSelection<T> {
  const _MeowDropdownSelection(this.value);

  final T? value;
}

class MeowDropdown<T> extends StatelessWidget {
  const MeowDropdown({
    super.key,
    required this.options,
    required this.onChanged,
    this.value,
    this.label,
    this.hint,
    this.sheetTitle,
    this.sheetSubtitle,
    this.searchHint,
    this.emptyText,
    this.labelPrefix,
    this.labelSuffix,
    this.prefix,
    this.suffix,
    this.presentation = MeowDropdownPresentation.sheet,
    this.enabled = true,
    this.searchable = true,
    this.dense = false,
    this.strings,
    this.footer,
    @Deprecated('Pass `strings: <AppStrings>` instead. See AGENTS.md §1.1.')
    this.isId = true,
  });

  final List<MeowDropdownOption<T>> options;
  final T? value;
  final ValueChanged<T?> onChanged;
  final String? label;
  final String? hint;
  final String? sheetTitle;
  final String? sheetSubtitle;
  final String? searchHint;
  final String? emptyText;
  final Widget? labelPrefix;
  final Widget? labelSuffix;
  final Widget? prefix;
  final Widget? suffix;
  final MeowDropdownPresentation presentation;
  final bool enabled;
  final bool searchable;
  final bool dense;
  final Widget? footer;

  /// Caller's resolved strings for default sheet copy (search hint / no
  /// results). Per AGENTS.md, the screen owns AppStrings resolution and passes
  /// the instance down. Falls back to English when null.
  final AppStrings? strings;
  @Deprecated('Pass `strings: <AppStrings>` instead. See AGENTS.md §1.1.')
  final bool isId;

  MeowDropdownOption<T>? _selectedOption() {
    for (final option in options) {
      if (option.value == value) return option;
    }
    return null;
  }

  static Future<T?> showSheet<T>(
    BuildContext context, {
    required String title,
    String? subtitle,
    required List<MeowDropdownOption<T>> options,
    T? selectedValue,
    String? searchHint,
    String? emptyText,
    bool searchable = true,
    bool useRootNavigator = false,
    AppStrings? strings,
    Widget? footer,
    @Deprecated('Pass `strings: <AppStrings>` instead. See AGENTS.md §1.1.')
    bool isId = true,
  }) async {
    // ignore: deprecated_member_use_from_same_package
    final s = strings ?? AppStrings(isId ? 'id' : 'en');
    final selection = await _showSheetSelection<T>(
      context,
      title: title,
      subtitle: subtitle,
      options: options,
      selectedValue: selectedValue,
      searchHint: searchHint ?? s.dropdownSearch,
      emptyText: emptyText ?? s.dropdownNoResults,
      searchable: searchable,
      useRootNavigator: useRootNavigator,
      footer: footer,
    );

    return selection?.value;
  }

  static Future<_MeowDropdownSelection<T>?> _showSheetSelection<T>(
    BuildContext context, {
    required String title,
    String? subtitle,
    required List<MeowDropdownOption<T>> options,
    T? selectedValue,
    required String searchHint,
    required String emptyText,
    required bool searchable,
    required bool useRootNavigator,
    Widget? footer,
  }) {
    return showModalBottomSheet<_MeowDropdownSelection<T>>(
      context: context,
      useRootNavigator: useRootNavigator,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return _MeowDropdownSheet<T>(
          title: title,
          subtitle: subtitle,
          searchHint: searchHint,
          emptyText: emptyText,
          options: options,
          selectedValue: selectedValue,
          searchable: searchable,
          footer: footer,
        );
      },
    );
  }

  Future<void> _showPicker(BuildContext context) async {
    if (!enabled) return;
    if (presentation == MeowDropdownPresentation.menu) {
      await _showMenuPicker(context);
      return;
    }

    await _showSheetPicker(context);
  }

  Future<void> _showSheetPicker(BuildContext context) async {
    final selected = _selectedOption();
    // ignore: deprecated_member_use_from_same_package
    final s = strings ?? AppStrings(isId ? 'id' : 'en');

    final picked = await MeowDropdown._showSheetSelection<T>(
      context,
      title: sheetTitle ?? label ?? '',
      subtitle: sheetSubtitle,
      searchHint: searchHint ?? s.dropdownSearch,
      emptyText: emptyText ?? s.dropdownNoResults,
      options: options,
      selectedValue: selected?.value,
      searchable: searchable,
      useRootNavigator: false,
      footer: footer,
    );

    if (picked != null) onChanged(picked.value);
  }

  Future<void> _showMenuPicker(BuildContext context) async {
    final cs = context.cs;
    final extras = context.extras;
    final selected = _selectedOption();
    final box = context.findRenderObject() as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final topLeft = box.localToGlobal(
      Offset(0, box.size.height + 6),
      ancestor: overlay,
    );
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(topLeft.dx, topLeft.dy, box.size.width, 0),
      Offset.zero & overlay.size,
    );

    final picked = await showMenu<_MeowDropdownSelection<T>>(
      context: context,
      position: position,
      color: cs.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: extras.inputBorder),
      ),
      constraints: BoxConstraints(
        minWidth: box.size.width,
        maxWidth: box.size.width,
      ),
      items: options.map((option) {
        return PopupMenuItem<_MeowDropdownSelection<T>>(
          value: _MeowDropdownSelection<T>(option.value),
          enabled: option.enabled,
          height: dense ? 42 : (option.subtitle == null ? 46 : 58),
          padding: EdgeInsets.zero,
          child: _MeowDropdownPopupItem<T>(
            option: option,
            selected: selected?.value == option.value,
            dense: dense,
          ),
        );
      }).toList(),
    );

    if (picked != null) onChanged(picked.value);
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final selected = _selectedOption();
    final effectivePrefix = prefix ?? selected?.prefix;
    final effectiveSuffix = suffix ?? selected?.suffix;
    final radius = dense ? 14.0 : 18.0;
    final minHeight = dense ? 42.0 : 56.0;
    final fieldPadding = dense
        ? const EdgeInsets.symmetric(horizontal: 13, vertical: 9)
        : const EdgeInsets.symmetric(horizontal: 16, vertical: 13);
    final fontSize = dense ? 12.0 : 14.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Row(
            children: [
              if (labelPrefix != null) ...[
                labelPrefix!,
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  label!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurfaceVariant,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
              if (labelSuffix != null) ...[
                const SizedBox(width: 8),
                labelSuffix!,
              ],
            ],
          ),
          const SizedBox(height: 8),
        ],
        Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(radius),
          child: Builder(
            builder: (fieldContext) {
              return InkWell(
                onTap: enabled ? () => _showPicker(fieldContext) : null,
                borderRadius: BorderRadius.circular(radius),
                splashColor: cs.primary.withValues(alpha: 0.08),
                highlightColor: cs.primary.withValues(alpha: 0.04),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minHeight),
                  child: Ink(
                    padding: fieldPadding,
                    decoration: BoxDecoration(
                      color: enabled ? extras.inputFill : extras.card,
                      borderRadius: BorderRadius.circular(radius),
                      border: Border.all(color: extras.inputBorder),
                    ),
                    child: Row(
                      children: [
                        if (effectivePrefix != null) ...[
                          effectivePrefix,
                          SizedBox(width: dense ? 9 : 12),
                        ],
                        Expanded(
                          child: Text(
                            selected?.label ?? hint ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: fontSize,
                              fontWeight: FontWeight.w600,
                              color: selected == null
                                  ? cs.onSurfaceVariant
                                  : cs.onSurface,
                            ),
                          ),
                        ),
                        if (effectiveSuffix != null) ...[
                          SizedBox(width: dense ? 8 : 10),
                          effectiveSuffix,
                        ],
                        SizedBox(width: dense ? 6 : 8),
                        Icon(
                          Icons.expand_more_rounded,
                          size: dense ? 18 : 20,
                          color: enabled
                              ? cs.onSurfaceVariant
                              : cs.onSurfaceVariant.withValues(alpha: 0.45),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MeowDropdownPopupItem<T> extends StatelessWidget {
  const _MeowDropdownPopupItem({
    required this.option,
    required this.selected,
    required this.dense,
  });

  final MeowDropdownOption<T> option;
  final bool selected;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 12 : 14,
        vertical: dense ? 8 : 10,
      ),
      child: Row(
        children: [
          if (option.prefix != null) ...[
            option.prefix!,
            SizedBox(width: dense ? 9 : 12),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: dense ? 12 : 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: selected ? cs.primary : cs.onSurface,
                  ),
                ),
                if (!dense && option.subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    option.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          if (option.suffix != null) ...[
            SizedBox(width: dense ? 8 : 12),
            option.suffix!,
          ],
          if (selected) ...[
            SizedBox(width: dense ? 8 : 10),
            Icon(Icons.check_rounded, size: dense ? 16 : 18, color: cs.primary),
          ],
        ],
      ),
    );
  }
}

class _MeowDropdownSheet<T> extends StatefulWidget {
  const _MeowDropdownSheet({
    required this.title,
    this.subtitle,
    required this.searchHint,
    required this.emptyText,
    required this.options,
    required this.selectedValue,
    required this.searchable,
    this.footer,
  });

  final String title;
  final String? subtitle;
  final String searchHint;
  final String emptyText;
  final List<MeowDropdownOption<T>> options;
  final T? selectedValue;
  final bool searchable;
  final Widget? footer;

  @override
  State<_MeowDropdownSheet<T>> createState() => _MeowDropdownSheetState<T>();
}

class _MeowDropdownSheetState<T> extends State<_MeowDropdownSheet<T>> {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  var _query = '';
  var _isClosing = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _close([T? value]) {
    if (_isClosing) return;
    _isClosing = true;
    _searchFocus.unfocus();
    Navigator.of(context).maybePop(_MeowDropdownSelection<T>(value));
  }

  void _dismiss() {
    if (_isClosing) return;
    _isClosing = true;
    _searchFocus.unfocus();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final filtered = _query.isEmpty
        ? widget.options
        : widget.options
              .where((option) => option.searchableText.contains(_query))
              .toList();

    return MeowSheet(
      title: widget.title,
      subtitle: widget.subtitle,
      onClose: _dismiss,
      contentPadding: EdgeInsets.zero,
      footer: widget.footer,
      children: [
        if (widget.searchable) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
            child: TextField(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              autofocus: widget.options.length > 6,
              onChanged: (value) {
                if (!mounted) return;
                setState(() => _query = value.trim().toLowerCase());
              },
              style: TextStyle(fontSize: 14, color: cs.onSurface),
              decoration: InputDecoration(
                hintText: widget.searchHint,
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: cs.onSurfaceVariant,
                ),
                filled: true,
                fillColor: extras.inputFill,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: extras.inputBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: extras.inputFocusBorder),
                ),
              ),
            ),
          ),
        ],
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            child: Center(
              child: Text(
                widget.emptyText,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            itemCount: filtered.length,
            separatorBuilder: (context, index) => const SizedBox(height: 4),
            itemBuilder: (context, index) {
              final option = filtered[index];
              final isSelected = widget.selectedValue == option.value;
              return _MeowDropdownOptionTile<T>(
                option: option,
                selected: isSelected,
                onTap: option.enabled ? () => _close(option.value) : null,
              );
            },
          ),
      ],
    );
  }
}

class _MeowDropdownOptionTile<T> extends StatelessWidget {
  const _MeowDropdownOptionTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final MeowDropdownOption<T> option;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final enabled = onTap != null;

    return Material(
      color: selected ? cs.primary.withValues(alpha: 0.10) : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              if (option.prefix != null) ...[
                Opacity(opacity: enabled ? 1 : 0.45, child: option.prefix!),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Opacity(
                  opacity: enabled ? 1 : 0.45,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        option.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: selected
                              ? FontWeight.w800
                              : FontWeight.w600,
                          color: selected ? cs.primary : cs.onSurface,
                        ),
                      ),
                      if (option.subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          option.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (option.suffix != null) ...[
                const SizedBox(width: 12),
                option.suffix!,
              ],
              if (selected) ...[
                const SizedBox(width: 10),
                Icon(Icons.check_rounded, size: 18, color: cs.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
