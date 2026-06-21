import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/widgets/widgets.dart';
import '../../../settings/data/app_language_provider.dart';
import '../user_db_repository.dart';

class DbCreateTableScreen extends ConsumerStatefulWidget {
  const DbCreateTableScreen({super.key});

  @override
  ConsumerState<DbCreateTableScreen> createState() => _DbCreateTableScreenState();
}

class _DbCreateTableScreenState extends ConsumerState<DbCreateTableScreen> {
  final _repo = UserDbRepository();
  final _nameController = TextEditingController();
  final _columnControllers = <({TextEditingController name, String type})>[];
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _addColumn();
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final col in _columnControllers) {
      col.name.dispose();
    }
    super.dispose();
  }

  void _addColumn() {
    setState(() {
      _columnControllers.add((
        name: TextEditingController(),
        type: 'TEXT',
      ));
    });
  }

  void _removeColumn(int index) {
    if (_columnControllers.length <= 1) return;
    setState(() {
      final col = _columnControllers.removeAt(index);
      col.name.dispose();
    });
  }

  bool _isValidIdentifier(String val) {
    return val.isNotEmpty && RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(val);
  }

  Future<void> _submit(AppStrings s) async {
    if (_submitting) return;
    final tableName = _nameController.text.trim();
    if (!_isValidIdentifier(tableName)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.dbManagerInvalidTableName)),
      );
      return;
    }

    final cols = <UserTableColumn>[];
    for (final colController in _columnControllers) {
      final colName = colController.name.text.trim();
      if (!_isValidIdentifier(colName)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${s.dbManagerInvalidColumnName} ("$colName")')),
        );
        return;
      }
      cols.add(UserTableColumn(name: colName, type: colController.type));
    }

    setState(() => _submitting = true);

    try {
      final res = await _repo.createTable(tableName, cols);
      if (!mounted) return;
      if (res.created) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.dbManagerCreateSuccess)),
        );
        Navigator.pop(context, true);
      } else {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.error ?? 'Error creating table')),
        );
      }
    } catch (e) {
      setState(() => _submitting = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));
    final cs = Theme.of(context).colorScheme;
    final isDark = cs.brightness == Brightness.dark;

    final typeOptions = [
      const MeowDropdownOption(value: 'TEXT', label: 'TEXT'),
      const MeowDropdownOption(value: 'VARCHAR', label: 'VARCHAR'),
      const MeowDropdownOption(value: 'INT', label: 'INT'),
      const MeowDropdownOption(value: 'INTEGER', label: 'INTEGER'),
      const MeowDropdownOption(value: 'REAL', label: 'REAL'),
      const MeowDropdownOption(value: 'BLOB', label: 'BLOB'),
      const MeowDropdownOption(value: 'PRIMARY KEY', label: 'PRIMARY KEY'),
      const MeowDropdownOption(value: 'INTEGER PRIMARY KEY', label: 'INTEGER PRIMARY KEY'),
      const MeowDropdownOption(value: 'TEXT PRIMARY KEY', label: 'TEXT PRIMARY KEY'),
      const MeowDropdownOption(value: 'VARCHAR(255)', label: 'VARCHAR(255)'),
    ];

    return Scaffold(
      backgroundColor: isDark ? cs.surface : const Color(0xFFFBFCFE),
      appBar: AppBar(
        title: Text(s.dbManagerCreateTableTitle),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: cs.onSurface,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.dbManagerTableName,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    MeowInput(
                      controller: _nameController,
                      hint: s.dbManagerTableName.toLowerCase(),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      s.dbManagerAutoColumnsInfo,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      s.dbManagerColumns,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (int i = 0; i < _columnControllers.length; i++) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              flex: 5,
                              child: MeowInput(
                                controller: _columnControllers[i].name,
                                hint: '${s.dbManagerColumnName.toLowerCase()} ${i + 1}',
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 4,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    s.dbManagerColumnType,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  MeowDropdown<String>(
                                    options: typeOptions,
                                    value: _columnControllers[i].type,
                                    onChanged: (val) {
                                      if (val != null) {
                                        setState(() {
                                          _columnControllers[i] = (
                                            name: _columnControllers[i].name,
                                            type: val,
                                          );
                                        });
                                      }
                                    },
                                    dense: true,
                                    strings: s,
                                  ),
                                ],
                              ),
                            ),
                            if (_columnControllers.length > 1) ...[
                              const SizedBox(width: 4),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: IconButton(
                                  icon: Icon(
                                    Icons.remove_circle_outline_rounded,
                                    color: cs.error,
                                    size: 22,
                                  ),
                                  onPressed: () => _removeColumn(i),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    MeowSecondaryButton(
                      label: s.dbManagerAddColumn,
                      onPressed: _addColumn,
                      icon: Icons.add_rounded,
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: MeowPrimaryButton(
                label: s.dbManagerCreateTableBtn,
                onPressed: _submitting ? null : () => _submit(s),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
