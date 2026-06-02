import 'package:flutter/material.dart';


import '../../../../app/theme.dart';
import '../data/api_config.dart';
import '../data/api_store_repository.dart';

/// API Store — lists all registered APIs as floating cards.
///
/// Follows AGENTS.md: floating surfaces, controlled emptiness, calm futuristic.
class ApiStoreScreen extends StatefulWidget {
  const ApiStoreScreen({super.key});

  @override
  State<ApiStoreScreen> createState() => _ApiStoreScreenState();
}

class _ApiStoreScreenState extends State<ApiStoreScreen> {
  List<ApiConfig> _apis = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final apis = await ApiStoreRepository.instance.list();
    if (mounted) setState(() { _apis = apis.toList(); _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? cs.surface : const Color(0xFFFBFCFE),
      appBar: AppBar(title: const Text('API Store')),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final result = await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const ApiEditorScreen()),
          );
          if (result == true) _load();
        },
        backgroundColor: cs.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: const CircleBorder(),
        child: const Icon(Icons.add_rounded, size: 28),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _apis.isEmpty
              ? _EmptyState(onAdd: () async {
                  final result = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(builder: (_) => const ApiEditorScreen()),
                  );
                  if (result == true) _load();
                })
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    18, 16, 18,
                    100 + MediaQuery.of(context).padding.bottom,
                  ),
                  itemCount: _apis.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _ApiCard(
                      config: _apis[i],
                      onTap: () async {
                        final result = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                            builder: (_) => ApiEditorScreen(config: _apis[i]),
                          ),
                        );
                        if (result == true) _load();
                      },
                      onDelete: () => _confirmDelete(_apis[i]),
                    ),
                  ),
                ),
    );
  }

  Future<void> _confirmDelete(ApiConfig config) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove API'),
        content: Text('Remove "${config.name}" from the store?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Remove', style: TextStyle(color: context.cs.error)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ApiStoreRepository.instance.remove(config.id);
      _load();
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// API Card
// ─────────────────────────────────────────────────────────────────────────────

class _ApiCard extends StatelessWidget {
  const _ApiCard({required this.config, this.onTap, this.onDelete});

  final ApiConfig config;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dynamicCount = config.queryParams
        .where((p) => p.mode == ParamMode.dynamic)
        .length;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        onLongPress: onDelete,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          decoration: BoxDecoration(
            color: isDark ? extras.card : const Color(0xFFF4F7FB),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: extras.subtleBorder),
          ),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _MethodBadge(method: config.method),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      config.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  if (config.auth.type != ApiAuthType.none)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(
                        Icons.lock_rounded,
                        size: 14,
                        color: extras.subtleText,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                config.url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: extras.subtleText,
                  fontFamily: 'monospace',
                ),
              ),
              if (dynamicCount > 0) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      Icons.tune_rounded,
                      size: 13,
                      color: cs.primary.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '$dynamicCount dynamic param${dynamicCount > 1 ? 's' : ''}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: cs.primary.withValues(alpha: 0.8),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Method Badge
// ─────────────────────────────────────────────────────────────────────────────

class _MethodBadge extends StatelessWidget {
  const _MethodBadge({required this.method});

  final String method;

  Color _color() {
    switch (method.toUpperCase()) {
      case 'GET':
        return const Color(0xFF22C55E);
      case 'POST':
        return const Color(0xFF3B82F6);
      case 'PUT':
      case 'PATCH':
        return const Color(0xFFF59E0B);
      case 'DELETE':
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF94A3B8);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _color();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        method.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty State
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({this.onAdd});

  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.cloud_outlined,
                size: 34,
                color: cs.primary.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'No APIs yet',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Register an API endpoint here, then any agent can call it by name via chat or workflows.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: extras.subtleText,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add API'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// API Editor Screen (Create / Edit)
// ─────────────────────────────────────────────────────────────────────────────

class ApiEditorScreen extends StatefulWidget {
  const ApiEditorScreen({super.key, this.config});

  final ApiConfig? config;
  bool get isEditing => config != null;

  @override
  State<ApiEditorScreen> createState() => _ApiEditorScreenState();
}

class _ApiEditorScreenState extends State<ApiEditorScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _authValueCtrl;
  late final TextEditingController _authHeaderCtrl;
  late final TextEditingController _bodyRawCtrl;

  String _method = 'GET';
  ApiAuthType _authType = ApiAuthType.none;
  final List<_KVRow> _headers = [];
  final List<_KVRow> _queryParams = [];
  bool _useRawBody = false;
  final List<_BodyTreeNode> _bodyNodes = [];

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _nameCtrl = TextEditingController(text: c?.name ?? '');
    _urlCtrl = TextEditingController(text: c?.url ?? '');
    _authValueCtrl = TextEditingController(text: c?.auth.value ?? '');
    _authHeaderCtrl = TextEditingController(text: c?.auth.headerName ?? '');
    _bodyRawCtrl = TextEditingController(text: c?.bodyRaw ?? '');
    _method = c?.method ?? 'GET';
    _authType = c?.auth.type ?? ApiAuthType.none;
    if (c != null) {
      for (final h in c.headers) {
        _headers.add(_KVRow(key: h.key, value: h.value, mode: h.mode, hint: h.hint ?? '', defaultValue: h.defaultValue ?? ''));
      }
      for (final q in c.queryParams) {
        _queryParams.add(_KVRow(key: q.key, value: q.value, mode: q.mode, hint: q.hint ?? '', defaultValue: q.defaultValue ?? ''));
      }
      _useRawBody = c.bodyMode == BodyMode.raw;
      if (c.bodyMode == BodyMode.tree) {
        for (final n in c.bodyTree) {
          _bodyNodes.add(_BodyTreeNode.fromBodyNode(n));
        }
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _authValueCtrl.dispose();
    _authHeaderCtrl.dispose();
    _bodyRawCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? cs.surface : const Color(0xFFFBFCFE),
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit API' : 'New API'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving...' : 'Save'),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          18, 12, 18,
          40 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          // Name
          _SectionLabel(label: 'Name'),
          const SizedBox(height: 8),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(hintText: 'e.g. GitHub Search API'),
          ),

          const SizedBox(height: 22),

          // URL
          _SectionLabel(label: 'URL'),
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(hintText: 'https://api.example.com/endpoint'),
            keyboardType: TextInputType.url,
          ),

          const SizedBox(height: 22),

          // Method
          _SectionLabel(label: 'Method'),
          const SizedBox(height: 8),
          _MethodSelector(
            value: _method,
            onChanged: (v) => setState(() => _method = v),
          ),

          const SizedBox(height: 22),

          // Auth
          _SectionLabel(label: 'Authentication'),
          const SizedBox(height: 8),
          _AuthSection(
            type: _authType,
            valueCtrl: _authValueCtrl,
            headerCtrl: _authHeaderCtrl,
            onTypeChanged: (t) => setState(() => _authType = t),
          ),

          const SizedBox(height: 22),

          // Headers
          _SectionLabel(label: 'Headers'),
          const SizedBox(height: 8),
          _KeyValueSection(
            rows: _headers,
            onChanged: () => setState(() {}),
            showDynamic: false,
          ),

          const SizedBox(height: 22),

          // Query Params
          _SectionLabel(label: 'Query Parameters'),
          const SizedBox(height: 8),
          _KeyValueSection(
            rows: _queryParams,
            onChanged: () => setState(() {}),
            showDynamic: true,
          ),

          // Body (only for non-GET)
          if (_method != 'GET') ...[
            const SizedBox(height: 22),
            Row(
              children: [
                _SectionLabel(label: 'Body'),
                const Spacer(),
                _BodyModeToggle(
                  isRaw: _useRawBody,
                  onChanged: (v) => setState(() => _useRawBody = v),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_useRawBody)
              TextField(
                controller: _bodyRawCtrl,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: '{"key": "value"}',
                  alignLabelWithHint: true,
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              )
            else
              _BodyTreeSection(
                nodes: _bodyNodes,
                onChanged: () => setState(() {}),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final url = _urlCtrl.text.trim();
    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and URL are required')),
      );
      return;
    }

    setState(() => _saving = true);

    final headers = _headers
        .where((r) => r.keyCtrl.text.trim().isNotEmpty)
        .map((r) => ApiParam(
              key: r.keyCtrl.text.trim(),
              value: r.valueCtrl.text.trim(),
              mode: r.mode,
              hint: r.mode == ParamMode.dynamic ? r.hintCtrl.text.trim() : null,
              defaultValue: r.mode == ParamMode.dynamic ? r.defaultCtrl.text.trim() : null,
            ))
        .toList();

    final queryParams = _queryParams
        .where((r) => r.keyCtrl.text.trim().isNotEmpty)
        .map((r) => ApiParam(
              key: r.keyCtrl.text.trim(),
              value: r.valueCtrl.text.trim(),
              mode: r.mode,
              hint: r.mode == ParamMode.dynamic ? r.hintCtrl.text.trim() : null,
              defaultValue: r.mode == ParamMode.dynamic ? r.defaultCtrl.text.trim() : null,
            ))
        .toList();

    final bodyRaw = _bodyRawCtrl.text.trim();
    final hasTreeNodes = _bodyNodes.any((n) => n.keyCtrl.text.trim().isNotEmpty);

    BodyMode bodyMode = BodyMode.none;
    List<BodyNode> bodyTree = [];
    String? finalBodyRaw;

    if (_useRawBody && bodyRaw.isNotEmpty) {
      bodyMode = BodyMode.raw;
      finalBodyRaw = bodyRaw;
    } else if (!_useRawBody && hasTreeNodes) {
      bodyMode = BodyMode.tree;
      bodyTree = _bodyNodes
          .where((n) => n.keyCtrl.text.trim().isNotEmpty)
          .map((n) => n.toBodyNode())
          .toList();
    }

    final config = ApiConfig(
      id: widget.config?.id ?? ApiConfig.generateId(),
      name: name,
      url: url,
      method: _method,
      auth: ApiAuth(
        type: _authType,
        value: _authValueCtrl.text.trim(),
        headerName: _authType == ApiAuthType.apiKeyHeader
            ? _authHeaderCtrl.text.trim()
            : null,
      ),
      headers: headers,
      queryParams: queryParams,
      bodyMode: bodyMode,
      bodyTree: bodyTree,
      bodyRaw: finalBodyRaw,
    );

    await ApiStoreRepository.instance.save(config);
    if (mounted) {
      Navigator.pop(context, true);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared Widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: context.extras.subtleText,
        letterSpacing: 0.3,
      ),
    );
  }
}

class _MethodSelector extends StatelessWidget {
  const _MethodSelector({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  static const _methods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Wrap(
      spacing: 8,
      children: _methods.map((m) {
        final selected = m == value;
        return ChoiceChip(
          label: Text(m),
          selected: selected,
          onSelected: (_) => onChanged(m),
          selectedColor: cs.primary.withValues(alpha: 0.15),
          backgroundColor: isDark ? extras.card : const Color(0xFFF4F7FB),
          side: BorderSide(
            color: selected ? cs.primary.withValues(alpha: 0.4) : extras.subtleBorder,
          ),
          labelStyle: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? cs.primary : cs.onSurfaceVariant,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 4),
        );
      }).toList(),
    );
  }
}

class _AuthSection extends StatelessWidget {
  const _AuthSection({
    required this.type,
    required this.valueCtrl,
    required this.headerCtrl,
    required this.onTypeChanged,
  });

  final ApiAuthType type;
  final TextEditingController valueCtrl;
  final TextEditingController headerCtrl;
  final ValueChanged<ApiAuthType> onTypeChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<ApiAuthType>(
          initialValue: type,
          decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
          items: const [
            DropdownMenuItem(value: ApiAuthType.none, child: Text('None')),
            DropdownMenuItem(value: ApiAuthType.bearer, child: Text('Bearer Token')),
            DropdownMenuItem(value: ApiAuthType.apiKeyHeader, child: Text('API Key in Header')),
            DropdownMenuItem(value: ApiAuthType.basic, child: Text('Basic Auth')),
          ],
          onChanged: (v) { if (v != null) onTypeChanged(v); },
        ),
        if (type == ApiAuthType.bearer) ...[
          const SizedBox(height: 12),
          TextField(
            controller: valueCtrl,
            decoration: const InputDecoration(hintText: 'Token value'),
            obscureText: true,
          ),
        ],
        if (type == ApiAuthType.apiKeyHeader) ...[
          const SizedBox(height: 12),
          TextField(
            controller: headerCtrl,
            decoration: const InputDecoration(hintText: 'Header name (e.g. X-API-Key)'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: valueCtrl,
            decoration: const InputDecoration(hintText: 'Key value'),
            obscureText: true,
          ),
        ],
        if (type == ApiAuthType.basic) ...[
          const SizedBox(height: 12),
          TextField(
            controller: valueCtrl,
            decoration: const InputDecoration(hintText: 'username:password'),
            obscureText: true,
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Key-Value Builder
// ─────────────────────────────────────────────────────────────────────────────

class _KVRow {
  _KVRow({String key = '', String value = '', this.mode = ParamMode.fixed, String hint = '', String defaultValue = ''})
    : keyCtrl = TextEditingController(text: key),
      valueCtrl = TextEditingController(text: value),
      hintCtrl = TextEditingController(text: hint),
      defaultCtrl = TextEditingController(text: defaultValue);

  final TextEditingController keyCtrl;
  final TextEditingController valueCtrl;
  final TextEditingController hintCtrl;
  final TextEditingController defaultCtrl;
  ParamMode mode;
}

class _KeyValueSection extends StatelessWidget {
  const _KeyValueSection({
    required this.rows,
    required this.onChanged,
    this.showDynamic = false,
  });

  final List<_KVRow> rows;
  final VoidCallback onChanged;
  final bool showDynamic;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      children: [
        ...rows.asMap().entries.map((entry) {
          final i = entry.key;
          final row = entry.value;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? extras.card : const Color(0xFFF4F7FB),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: extras.subtleBorder),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: row.keyCtrl,
                          decoration: const InputDecoration(
                            hintText: 'Key',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: row.valueCtrl,
                          decoration: InputDecoration(
                            hintText: row.mode == ParamMode.dynamic ? 'Hint' : 'Value',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: () {
                          rows.removeAt(i);
                          onChanged();
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(Icons.close_rounded, size: 16, color: extras.subtleText),
                        ),
                      ),
                    ],
                  ),
                  if (showDynamic) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        InkWell(
                          onTap: () {
                            row.mode = row.mode == ParamMode.fixed
                                ? ParamMode.dynamic
                                : ParamMode.fixed;
                            onChanged();
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: row.mode == ParamMode.dynamic
                                  ? cs.primary.withValues(alpha: 0.1)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: row.mode == ParamMode.dynamic
                                    ? cs.primary.withValues(alpha: 0.3)
                                    : extras.subtleBorder,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  row.mode == ParamMode.dynamic
                                      ? Icons.smart_toy_rounded
                                      : Icons.lock_rounded,
                                  size: 12,
                                  color: row.mode == ParamMode.dynamic
                                      ? cs.primary
                                      : extras.subtleText,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  row.mode == ParamMode.dynamic ? 'Dynamic' : 'Fixed',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: row.mode == ParamMode.dynamic
                                        ? cs.primary
                                        : extras.subtleText,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (row.mode == ParamMode.dynamic) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: row.defaultCtrl,
                              decoration: const InputDecoration(
                                hintText: 'Default',
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              ),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
        TextButton.icon(
          onPressed: () {
            rows.add(_KVRow());
            onChanged();
          },
          icon: Icon(Icons.add_rounded, size: 16, color: cs.primary),
          label: Text(
            'Add',
            style: TextStyle(fontSize: 13, color: cs.primary),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Body Tree Node Model
// ─────────────────────────────────────────────────────────────────────────────

class _BodyTreeNode {
  _BodyTreeNode({
    String key = '',
    String value = '',
    this.type = 'string',
    this.mode = ParamMode.fixed,
    String hint = '',
    String defaultValue = '',
    List<_BodyTreeNode>? children,
  })  : keyCtrl = TextEditingController(text: key),
        valueCtrl = TextEditingController(text: value),
        hintCtrl = TextEditingController(text: hint),
        defaultCtrl = TextEditingController(text: defaultValue),
        children = children ?? [];

  final TextEditingController keyCtrl;
  final TextEditingController valueCtrl;
  final TextEditingController hintCtrl;
  final TextEditingController defaultCtrl;
  String type; // string, number, boolean, object, array
  ParamMode mode;
  List<_BodyTreeNode> children;
  bool expanded = true;

  factory _BodyTreeNode.fromBodyNode(BodyNode node) {
    return _BodyTreeNode(
      key: node.key,
      value: node.value ?? '',
      type: node.type,
      mode: node.mode,
      hint: node.hint ?? '',
      defaultValue: node.defaultValue ?? '',
      children: [
        ...node.children.map((c) => _BodyTreeNode.fromBodyNode(c)),
        ...node.items.map((c) => _BodyTreeNode.fromBodyNode(c)),
      ],
    );
  }

  BodyNode toBodyNode() {
    final childNodes = children
        .where((c) => c.keyCtrl.text.trim().isNotEmpty)
        .map((c) => c.toBodyNode())
        .toList();

    return BodyNode(
      key: keyCtrl.text.trim(),
      type: type,
      value: (type != 'object' && type != 'array') ? valueCtrl.text.trim() : null,
      mode: mode,
      hint: mode == ParamMode.dynamic ? hintCtrl.text.trim() : null,
      defaultValue: mode == ParamMode.dynamic ? defaultCtrl.text.trim() : null,
      children: type == 'object' ? childNodes : [],
      items: type == 'array' ? childNodes : [],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Body Mode Toggle (Tree ↔ Raw)
// ─────────────────────────────────────────────────────────────────────────────

class _BodyModeToggle extends StatelessWidget {
  const _BodyModeToggle({required this.isRaw, required this.onChanged});
  final bool isRaw;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final extras = context.extras;

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: extras.inputFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: extras.subtleBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _toggleChip(context, label: 'Tree', active: !isRaw, onTap: () => onChanged(false)),
          _toggleChip(context, label: 'Raw', active: isRaw, onTap: () => onChanged(true)),
        ],
      ),
    );
  }

  Widget _toggleChip(BuildContext context, {required String label, required bool active, required VoidCallback onTap}) {
    final cs = context.cs;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? cs.primary.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: active ? cs.primary : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Body Tree Section (interactive builder)
// ─────────────────────────────────────────────────────────────────────────────

class _BodyTreeSection extends StatelessWidget {
  const _BodyTreeSection({required this.nodes, required this.onChanged});
  final List<_BodyTreeNode> nodes;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...nodes.asMap().entries.map((entry) {
          return _BodyNodeTile(
            node: entry.value,
            depth: 0,
            onChanged: onChanged,
            onRemove: () {
              nodes.removeAt(entry.key);
              onChanged();
            },
          );
        }),
        TextButton.icon(
          onPressed: () => _showAddNodeDialog(context),
          icon: Icon(Icons.add_rounded, size: 16, color: cs.primary),
          label: Text('Add field', style: TextStyle(fontSize: 13, color: cs.primary)),
        ),
      ],
    );
  }

  void _showAddNodeDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => _AddNodeSheet(
        onAdd: (type) {
          nodes.add(_BodyTreeNode(type: type));
          onChanged();
          Navigator.pop(ctx);
        },
      ),
    );
  }
}

class _BodyNodeTile extends StatelessWidget {
  const _BodyNodeTile({
    required this.node,
    required this.depth,
    required this.onChanged,
    required this.onRemove,
  });

  final _BodyTreeNode node;
  final int depth;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  IconData _typeIcon() {
    switch (node.type) {
      case 'string': return Icons.text_fields_rounded;
      case 'number': return Icons.tag_rounded;
      case 'boolean': return Icons.toggle_on_rounded;
      case 'object': return Icons.data_object_rounded;
      case 'array': return Icons.data_array_rounded;
      default: return Icons.text_fields_rounded;
    }
  }

  Color _typeColor(ColorScheme cs) {
    switch (node.type) {
      case 'string': return const Color(0xFF22C55E);
      case 'number': return const Color(0xFFF59E0B);
      case 'boolean': return const Color(0xFF8B5CF6);
      case 'object': return cs.primary;
      case 'array': return const Color(0xFFEC4899);
      default: return cs.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isContainer = node.type == 'object' || node.type == 'array';

    return Padding(
      padding: EdgeInsets.only(left: depth * 16.0, bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isDark ? extras.card : const Color(0xFFF4F7FB),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: extras.subtleBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row: type icon + key + value/hint + remove
            Row(
              children: [
                Icon(_typeIcon(), size: 14, color: _typeColor(cs)),
                const SizedBox(width: 6),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: node.keyCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Key',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                if (!isContainer) ...[
                  const SizedBox(width: 6),
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: node.mode == ParamMode.dynamic ? node.hintCtrl : node.valueCtrl,
                      decoration: InputDecoration(
                        hintText: node.mode == ParamMode.dynamic ? 'Hint for agent' : 'Value',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      style: const TextStyle(fontSize: 12),
                      onChanged: (_) => onChanged(),
                    ),
                  ),
                ],
                const SizedBox(width: 4),
                InkWell(
                  onTap: onRemove,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close_rounded, size: 14, color: extras.subtleText),
                  ),
                ),
              ],
            ),

            // Mode toggle row
            const SizedBox(height: 6),
            Row(
              children: [
                GestureDetector(
                  onTap: () {
                    node.mode = node.mode == ParamMode.fixed
                        ? ParamMode.dynamic
                        : ParamMode.fixed;
                    onChanged();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: node.mode == ParamMode.dynamic
                          ? cs.primary.withValues(alpha: 0.1)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: node.mode == ParamMode.dynamic
                            ? cs.primary.withValues(alpha: 0.3)
                            : extras.subtleBorder,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          node.mode == ParamMode.dynamic ? Icons.smart_toy_rounded : Icons.lock_rounded,
                          size: 10,
                          color: node.mode == ParamMode.dynamic ? cs.primary : extras.subtleText,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          node.mode == ParamMode.dynamic ? 'Dynamic' : 'Fixed',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: node.mode == ParamMode.dynamic ? cs.primary : extras.subtleText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (node.mode == ParamMode.dynamic && !isContainer) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: node.defaultCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Default',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      ),
                      style: const TextStyle(fontSize: 11),
                      onChanged: (_) => onChanged(),
                    ),
                  ),
                ],
                if (isContainer) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      node.expanded = !node.expanded;
                      onChanged();
                    },
                    child: Icon(
                      node.expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      size: 18,
                      color: extras.subtleText,
                    ),
                  ),
                ],
              ],
            ),

            // Children (for object/array)
            if (isContainer && node.expanded) ...[
              const SizedBox(height: 8),
              ...node.children.asMap().entries.map((entry) {
                return _BodyNodeTile(
                  node: entry.value,
                  depth: 0,
                  onChanged: onChanged,
                  onRemove: () {
                    node.children.removeAt(entry.key);
                    onChanged();
                  },
                );
              }),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: TextButton.icon(
                  onPressed: () => _showAddChildDialog(context),
                  icon: Icon(Icons.add_rounded, size: 14, color: cs.primary.withValues(alpha: 0.7)),
                  label: Text(
                    'Add ${node.type == 'array' ? 'item' : 'field'}',
                    style: TextStyle(fontSize: 11, color: cs.primary.withValues(alpha: 0.7)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showAddChildDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => _AddNodeSheet(
        onAdd: (type) {
          node.children.add(_BodyTreeNode(type: type));
          onChanged();
          Navigator.pop(ctx);
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Add Node Type Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _AddNodeSheet extends StatelessWidget {
  const _AddNodeSheet({required this.onAdd});
  final ValueChanged<String> onAdd;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add Field',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: cs.onSurface),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _typeChip(context, 'string', Icons.text_fields_rounded, const Color(0xFF22C55E)),
                _typeChip(context, 'number', Icons.tag_rounded, const Color(0xFFF59E0B)),
                _typeChip(context, 'boolean', Icons.toggle_on_rounded, const Color(0xFF8B5CF6)),
                _typeChip(context, 'object', Icons.data_object_rounded, cs.primary),
                _typeChip(context, 'array', Icons.data_array_rounded, const Color(0xFFEC4899)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _typeChip(BuildContext context, String type, IconData icon, Color color) {
    return GestureDetector(
      onTap: () => onAdd(type),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(
              type,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
