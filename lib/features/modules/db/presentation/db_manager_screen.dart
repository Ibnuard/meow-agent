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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(s.dbManagerDropSuccess)));
        _loadTables();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.error ?? s.dbManagerDropError)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(s.dbManagerTitle),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: cs.onSurface,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: cs.brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
          statusBarBrightness: cs.brightness == Brightness.dark
              ? Brightness.dark
              : Brightness.light,
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
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
                                color: cs.onSurfaceVariant.withValues(
                                  alpha: 0.08,
                                ),
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
          builder: (_) => DbTableDetailsScreen(tableName: table.name),
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
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
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
      MaterialPageRoute(builder: (_) => const DbCreateTableScreen()),
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
  ConsumerState<DbTableDetailsScreen> createState() =>
      _DbTableDetailsScreenState();
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
          _tableInfo = null;
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(s.dbManagerDeleteRowSuccess)));
        _loadDetails();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.error ?? s.dbManagerDeleteRowError)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(s.dbManagerDropSuccess)));
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.error ?? s.dbManagerDropError)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  List<UserTableColumn> get _visibleColumns =>
      _tableInfo?.columns
          .where(
            (column) => column.name != '_id' && column.name != '_created_at',
          )
          .toList(growable: false) ??
      const [];

  Widget _buildCompactTable(AppStrings s, ColorScheme cs) {
    final columns = _visibleColumns;
    return LayoutBuilder(
      builder: (context, constraints) {
        const indexWidth = 42.0;
        const actionWidth = 48.0;
        const cardBorderInset = 2.0;
        final availableForColumns =
            constraints.maxWidth - cardBorderInset - indexWidth - actionWidth;
        final naturalColumnWidth = columns.isEmpty
            ? availableForColumns
            : availableForColumns / columns.length;
        final columnWidth = columns.length <= 2
            ? naturalColumnWidth.clamp(132.0, 220.0).toDouble()
            : 148.0;
        final calculatedWidth =
            cardBorderInset +
            indexWidth +
            actionWidth +
            (columnWidth * columns.length);
        final tableWidth = calculatedWidth < constraints.maxWidth
            ? constraints.maxWidth
            : calculatedWidth;

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            height: constraints.maxHeight,
            child: MeowCard(
              padding: EdgeInsets.zero,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Column(
                  children: [
                    Container(
                      height: 46,
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.045),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(20),
                        ),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: indexWidth,
                            child: Center(
                              child: Text(
                                '#',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                          for (final column in columns)
                            SizedBox(
                              width: columnWidth,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      column.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                        color: cs.onSurface,
                                      ),
                                    ),
                                    Text(
                                      column.type,
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w600,
                                        color: cs.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          const SizedBox(width: actionWidth),
                        ],
                      ),
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.08),
                    ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _loadDetails,
                        child: ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.zero,
                          itemCount: _rows.length,
                          separatorBuilder: (context, index) => Divider(
                            height: 1,
                            thickness: 1,
                            color: cs.onSurfaceVariant.withValues(alpha: 0.07),
                          ),
                          itemBuilder: (context, index) {
                            final row = _rows[index];
                            return Container(
                              constraints: const BoxConstraints(minHeight: 56),
                              color: index.isOdd
                                  ? cs.primary.withValues(alpha: 0.018)
                                  : Colors.transparent,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: indexWidth,
                                    child: Center(
                                      child: Text(
                                        '${index + 1}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ),
                                  for (final column in columns)
                                    SizedBox(
                                      width: columnWidth,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 10,
                                        ),
                                        child: Text(
                                          _formatCellValue(row[column.name]),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            height: 1.3,
                                            color: cs.onSurface,
                                          ),
                                        ),
                                      ),
                                    ),
                                  SizedBox(
                                    width: actionWidth,
                                    child: IconButton(
                                      tooltip: s.dbManagerDeleteRow,
                                      icon: Icon(
                                        Icons.delete_outline_rounded,
                                        color: cs.error.withValues(alpha: 0.72),
                                        size: 18,
                                      ),
                                      onPressed: () => _deleteRow(row, s),
                                      visualDensity: VisualDensity.compact,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: actionWidth,
                                            height: 48,
                                          ),
                                      padding: EdgeInsets.zero,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _formatCellValue(Object? value) {
    if (value == null) return '—';
    final text = value.toString().trim();
    return text.isEmpty ? '—' : text;
  }

  @override
  Widget build(BuildContext context) {
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(widget.tableName),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: cs.onSurface,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: cs.brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
          statusBarBrightness: cs.brightness == Brightness.dark
              ? Brightness.dark
              : Brightness.light,
        ),
        actions: [
          IconButton(
            tooltip: s.dbManagerDropConfirm,
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
            ? Center(
                child: Text(
                  s.dbManagerTableNotFound,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.table_rows_rounded,
                            size: 17,
                            color: cs.primary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '${_rows.length} ${s.dbManagerRows}  •  '
                          '${_visibleColumns.length} ${s.dbManagerColumns}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _rows.isEmpty
                        ? Center(
                            child: Text(
                              s.dbManagerNoRows,
                              style: TextStyle(color: cs.onSurfaceVariant),
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            child: _buildCompactTable(s, cs),
                          ),
                  ),
                ],
              ),
      ),
    );
  }
}
