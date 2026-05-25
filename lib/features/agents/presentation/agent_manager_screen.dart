import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../settings/data/app_language_provider.dart';
import '../../providers/data/provider_config.dart';
import '../../providers/data/provider_repository.dart';
import '../data/agent_model.dart';
import '../data/agent_repository.dart';
import '../data/workspace_service.dart';
import 'workspace_directory_screen.dart';

/// Screen to add or edit an agent.
///
/// Shows: Agent Name + Provider dropdown.
/// If no providers exist, shows a CTA to add one first.
class AgentManagerScreen extends ConsumerStatefulWidget {
  const AgentManagerScreen({super.key, this.agentId});

  final String? agentId;

  @override
  ConsumerState<AgentManagerScreen> createState() => _AgentManagerScreenState();
}

class _AgentManagerScreenState extends ConsumerState<AgentManagerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _contextLengthController = TextEditingController(text: '8191');
  String? _selectedProviderId;
  bool _saving = false;
  String? _existingId;
  String? _workspacePath;

  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }

  @override
  void initState() {
    super.initState();
    if (widget.agentId != null) {
      _loadExisting();
    }
  }

  void _loadExisting() {
    final agents = ref.read(agentListProvider);
    final existing = agents.where((a) => a.id == widget.agentId).firstOrNull;
    if (existing != null) {
      _existingId = existing.id;
      _nameController.text = existing.name;
      _selectedProviderId = existing.providerId;
      _contextLengthController.text = existing.maxContextLength.toString();
      _loadWorkspacePath(existing.id, agentName: existing.name);
    }
  }

  Future<void> _loadWorkspacePath(String agentId, {String? agentName}) async {
    final path = await ref.read(workspaceServiceProvider).getWorkspacePath(
      agentId,
      agentName: agentName,
    );
    if (mounted) setState(() => _workspacePath = path);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _contextLengthController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedProviderId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.pleaseSelectProvider)),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final maxCtx = int.tryParse(_contextLengthController.text.trim()) ?? 8191;
      final agent = AgentModel(
        id: _existingId,
        name: _nameController.text.trim(),
        providerId: _selectedProviderId!,
        maxContextLength: maxCtx.clamp(512, 1000000),
      );
      await ref.read(agentListProvider.notifier).save(agent);
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(AppRoutes.home);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _goAddProvider() async {
    final result = await context.push<String>(AppRoutes.addProvider);
    if (result != null && mounted) {
      setState(() => _selectedProviderId = result);
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteAgent),
        content: Text(s.deleteAgentBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFF87171),
            ),
            child: Text(s.delete),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await ref.read(agentListProvider.notifier).delete(widget.agentId!);
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(AppRoutes.home);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final providersAsync = ref.watch(providerListProvider);
    final isEditing = widget.agentId != null;
    ref.watch(appLanguageProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? s.editAgent : s.setupNewAgent),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go(AppRoutes.home);
            }
          },
        ),
      ),
      body: SafeArea(
        child: providersAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (providers) => _buildForm(context, providers),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context, List<ProviderConfig> providers) {
    final cs = context.cs;
    final extras = context.extras;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 40),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Workspace info (edit mode only).
            if (widget.agentId != null && _workspacePath != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Material(
                  color: extras.card,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => WorkspaceDirectoryScreen(
                            workspacePath: _workspacePath!,
                            agentName: _nameController.text.isNotEmpty
                                ? _nameController.text
                                : 'Agent',
                          ),
                        ),
                      );
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: extras.subtleBorder, width: 1),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.folder_outlined, size: 18, color: cs.primary),
                                    const SizedBox(width: 8),
                                    Text(
                                      s.agentWorkspace,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: cs.onSurface,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _workspacePath!,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w400,
                                    color: cs.onSurfaceVariant,
                                    fontFamily: 'monospace',
                                    height: 1.4,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],

            // Agent name section.
            MeowSection(
              title: s.agentSection,
              subtitle: s.agentSectionDesc,
              child: MeowInput(
                controller: _nameController,
                label: s.agentName,
                hint: s.agentNameHint,
                validator: (v) {
                  if ((v ?? '').trim().isEmpty) return s.nameRequired;
                  return null;
                },
              ),
            ),

            // Provider section.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Section header with add button.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.providerSection,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              s.providerSectionDesc,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: cs.onSurfaceVariant,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      _AddProviderButton(onTap: _goAddProvider, s: s),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (providers.isEmpty)
                    _ProviderEmptyState(s: s)
                  else ...[
                    // Provider dropdown.
                    Text(
                      s.selectProvider,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurfaceVariant,
                        letterSpacing: 0.1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: extras.inputFill,
                        borderRadius: BorderRadius.circular(16),
                        border:
                            Border.all(color: extras.inputBorder, width: 1),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedProviderId,
                          isExpanded: true,
                          hint: Text(
                            s.chooseProvider,
                            style: TextStyle(
                              color: extras.subtleText,
                              fontSize: 15,
                            ),
                          ),
                          dropdownColor: cs.brightness == Brightness.dark
                              ? const Color(0xFF0F172A)
                              : cs.surface,
                          borderRadius: BorderRadius.circular(16),
                          icon: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: cs.onSurfaceVariant,
                          ),
                          items: providers.map((p) {
                            return DropdownMenuItem(
                              value: p.id,
                              child: Text(
                                '${p.nickname}  ·  ${p.model}',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: cs.onSurface,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: (v) =>
                              setState(() => _selectedProviderId = v),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Max Context Length section.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.isId ? 'Konteks Maksimum' : 'Max Context Length',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    s.isId
                        ? 'Batas token konteks untuk model ini. Sesuaikan dengan spesifikasi model yang dipakai.'
                        : 'Token context limit for this model. Adjust based on your model specs.',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: cs.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: extras.inputFill,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: extras.inputBorder, width: 1),
                    ),
                    child: TextFormField(
                      controller: _contextLengthController,
                      keyboardType: TextInputType.number,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                      decoration: InputDecoration(
                        hintText: '8191',
                        hintStyle: TextStyle(
                          color: extras.subtleText,
                          fontSize: 15,
                        ),
                        suffixText: 'tokens',
                        suffixStyle: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                        ),
                        filled: false,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        if (n == null || n < 512) {
                          return s.isId ? 'Minimal 512 tokens' : 'Minimum 512 tokens';
                        }
                        return null;
                      },
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            // Save button.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: MeowPrimaryButton(
                label: _saving ? s.saving : s.saveAgent,
                icon: Icons.check_rounded,
                loading: _saving,
                onPressed: _saving ? null : _save,
              ),
            ),

            // Delete button (edit mode only).
            if (widget.agentId != null) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextButton(
                  onPressed: _confirmDelete,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFF87171),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.delete_outline_rounded, size: 18),
                      SizedBox(width: 8),
                      Text(
                        s.deleteAgent,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Rounded rectangle add button with soft blue glow.
class _AddProviderButton extends StatelessWidget {
  const _AddProviderButton({required this.onTap, required this.s});
  final VoidCallback onTap;
  final AppStrings s;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cs.primary.withValues(alpha: 0.2),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: cs.primary.withValues(alpha: 0.15),
              blurRadius: 12,
              spreadRadius: -2,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, color: cs.primary, size: 16),
            const SizedBox(width: 4),
            Text(
              s.add,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Simple clean empty state — no button, just a message.
class _ProviderEmptyState extends StatelessWidget {
  const _ProviderEmptyState({required this.s});

  final AppStrings s;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: extras.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: extras.subtleBorder, width: 1),
      ),
      child: Column(
        children: [
          Icon(
            Icons.dns_outlined,
            size: 32,
            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            s.noProvidersYet,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            s.noProvidersTapAddBtn,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
