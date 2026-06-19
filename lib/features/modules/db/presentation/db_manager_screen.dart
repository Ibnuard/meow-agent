import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/widgets/widgets.dart';
import '../../../settings/data/app_language_provider.dart';
import '../user_db_repository.dart';
import 'db_create_table_screen.dart';

class DbManagerScreen extends ConsumerStatefulWidget {
  const DbManagerScreen({super.key});

  @override
  ConsumerState<DbManagerScreen> createState() => _DbManagerScreenState();
}

class _DbManagerScreenState extends ConsumerState<DbManagerScreen> {
  final _repo = UserDbRepository();
  List<UserTableInfo> _tables = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTables();
  }

  Future<void> _loadTables() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _repo.listTables();
      setState(() {
        _tables = list;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _dropTable(UserTableInfo table, AppStrings s) async {
    final confirmed = await showMeowConfirmDialog(
      context,
      title: s.dbManagerDropConfirm,
      message: s.dbManagerDropConfirmDesc(table.name),
      confirmLabel: s.delete,
      strings: s,
      destructive: true,
    );
    if (!confirmed) return;
    if (!mounted) return;

    try {
      final res = await _repo.dropTable(table.name);
      if (!mounted) return;
      if (res.dropped) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.dbManagerDropSuccess)),
        );
        _loadTables();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.error ?? 'Error dropping table')),
        );
      }
    } catch (e) {
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

    return Scaffold(
      backgroundColor: cs.brightness == Brightness.dark ? cs.surface : const Color(0xFFFBFCFE),
      appBar: AppBar(
        title: Text(s.dbManagerTitle),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: cs.onSurface,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: cs.brightness == Brightness.dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: cs.brightness == Brightness.dark ? Brightness.dark : Brightness.light,
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _error!,
                        style: TextStyle(color: cs.error),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : _tables.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 72,
                                height: 72,
                                decoration: BoxDecoration(
                                  color: cs.primary.withValues(alpha: 0.08),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.storage_rounded,
                                  size: 32,
                                  color: cs.primary,
                                ),
                              ),
                              const SizedBox(height: 20),
                              Text(
                                s.dbManagerEmpty,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: cs.onSurface,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                s.dbManagerEmptyDesc,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadTables,
                        child: ListView(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          children: [
                            MeowCard(
                              padding: EdgeInsets.zero,
                              child: Column(
                                children: [
                                  for (int i = 0; i < _tables.length; i++) ...[
                                    _buildTableItem(_tables[i], s, cs),
                                    if (i < _tables.length - 1)
                                      Divider(
                                        height: 1,
                                        thickness: 1,
                                        color: cs.onSurfaceVariant.withValues(alpha: 0.08),
                                        indent: 64,
                                      ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _navigateToCreateTable,
        backgroundColor: cs.primary,
        foregroundColor: Colors.white,
        elevation: 2,
        child: const Icon(Icons.add_rounded),
      ),
    );
  }

  Widget _buildTableItem(UserTableInfo table, AppStrings s, ColorScheme cs) {
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DbTableDetailsScreen(
            tableName: table.name,
          ),
        ),
      ).then((_) => _loadTables()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.table_chart_rounded,
                color: cs.primary,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    table.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${table.rowCount} ${s.dbManagerRows} • ${table.columns.length} ${s.dbManagerColumns}',
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                Icons.delete_outline_rounded,
                color: cs.error,
                size: 18,
              ),
              onPressed: () => _dropTable(table, s),
            ),
          ],
        ),
      ),
    );
  }

  void _navigateToCreateTable() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const DbCreateTableScreen(),
      ),
    ).then((created) {
      if (created == true) {
        _loadTables();
      }
    });
  }
}

class DbTableDetailsScreen extends ConsumerStatefulWidget {
  const DbTableDetailsScreen({super.key, required this.tableName});

  final String tableName;

  @override
  ConsumerState<DbTableDetailsScreen> createState() => _DbTableDetailsScreenState();
}

class _DbTableDetailsScreenState extends ConsumerState<DbTableDetailsScreen> {
  final _repo = UserDbRepository();
  UserTableInfo? _tableInfo;
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await _repo.describeTable(widget.tableName);
      if (info == null) {
        setState(() {
          _error = 'Table not found';
          _loading = false;
        });
        return;
      }
      final queryRes = await _repo.query('SELECT * FROM "${widget.tableName}"');
      setState(() {
        _tableInfo = info;
        _rows = queryRes.rows ?? [];
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _deleteRow(Map<String, dynamic> row, AppStrings s) async {
    final confirmed = await showMeowConfirmDialog(
      context,
      title: s.dbManagerDeleteRow,
      message: s.dbManagerDeleteRowConfirm,
      confirmLabel: s.delete,
      strings: s,
      destructive: true,
    );
    if (!confirmed) return;
    if (!mounted) return;

    final idVal = row['_id'];
    if (idVal == null) return;

    try {
      final res = await _repo.delete(
        widget.tableName,
        whereClause: '_id = ?',
        whereArgs: [idVal],
      );
      if (!mounted) return;
      if (res.error == null && res.deleted > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.dbManagerDeleteRowSuccess)),
        );
        _loadDetails();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.error ?? 'Error deleting row')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _dropTable(AppStrings s) async {
    final confirmed = await showMeowConfirmDialog(
      context,
      title: s.dbManagerDropConfirm,
      message: s.dbManagerDropConfirmDesc(widget.tableName),
      confirmLabel: s.delete,
      strings: s,
      destructive: true,
    );
    if (!confirmed) return;
    if (!mounted) return;

    try {
      final res = await _repo.dropTable(widget.tableName);
      if (!mounted) return;
      if (res.dropped) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.dbManagerDropSuccess)),
        );
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.error ?? 'Error dropping table')),
        );
      }
    } catch (e) {
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

    return Scaffold(
      backgroundColor: cs.brightness == Brightness.dark ? cs.surface : const Color(0xFFFBFCFE),
      appBar: AppBar(
        title: Text(widget.tableName),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: cs.onSurface,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: cs.brightness == Brightness.dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: cs.brightness == Brightness.dark ? Brightness.dark : Brightness.light,
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.delete_forever_rounded, color: cs.error),
            onPressed: () => _dropTable(s),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _error!,
                        style: TextStyle(color: cs.error),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : _tableInfo == null
                    ? const Center(child: Text('Table details not found.'))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Schema Header
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (final col in _tableInfo!.columns)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: Chip(
                                        label: Text(
                                          '${col.name} (${col.type})',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: cs.primary,
                                          ),
                                        ),
                                        backgroundColor: cs.primary.withValues(alpha: 0.08),
                                        side: BorderSide(color: cs.primary.withValues(alpha: 0.15)),
                                        padding: EdgeInsets.zero,
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: _rows.isEmpty
                                ? Center(
                                    child: Text(
                                      s.dbManagerEmpty,
                                      style: TextStyle(color: cs.onSurfaceVariant),
                                    ),
                                  )
                                : ListView.builder(
                                    padding: const EdgeInsets.all(16),
                                    itemCount: _rows.length,
                                    itemBuilder: (context, index) {
                                      final row = _rows[index];
                                      final visibleData = Map<String, dynamic>.from(row)
                                        ..remove('_id')
                                        ..remove('_created_at');
                                      return Padding(
                                        padding: const EdgeInsets.only(bottom: 12),
                                        child: MeowCard(
                                          child: Padding(
                                            padding: const EdgeInsets.all(16),
                                            child: Row(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      for (final entry in visibleData.entries)
                                                        Padding(
                                                          padding: const EdgeInsets.only(bottom: 6),
                                                          child: Row(
                                                            crossAxisAlignment: CrossAxisAlignment.start,
                                                            children: [
                                                              SizedBox(
                                                                width: 100,
                                                                child: Text(
                                                                  entry.key,
                                                                  style: TextStyle(
                                                                    fontSize: 12,
                                                                    fontWeight: FontWeight.w600,
                                                                    color: cs.onSurfaceVariant,
                                                                  ),
                                                                ),
                                                              ),
                                                              const SizedBox(width: 8),
                                                              Expanded(
                                                                child: Text(
                                                                  '${entry.value}',
                                                                  style: TextStyle(
                                                                    fontSize: 13,
                                                                    color: cs.onSurface,
                                                                  ),
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                                IconButton(
                                                  icon: Icon(
                                                    Icons.delete_outline_rounded,
                                                    color: cs.error.withValues(alpha: 0.7),
                                                    size: 18,
                                                  ),
                                                  onPressed: () => _deleteRow(row, s),
                                                  padding: EdgeInsets.zero,
                                                  constraints: const BoxConstraints(),
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
                      ),
      ),
    );
  }
}
