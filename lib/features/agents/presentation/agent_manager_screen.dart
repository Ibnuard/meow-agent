import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../settings/data/app_language_provider.dart';
import '../../providers/data/provider_config.dart';
import '../../providers/data/provider_repository.dart';
import '../data/agent_appearance.dart';
import '../data/agent_model.dart';
import '../data/agent_repository.dart';
import '../data/workspace_service.dart';
import 'agent_profile_editor.dart';
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
  String? _selectedModel;
  String _iconKey = kDefaultAgentIconKey;
  String _colorKey = kDefaultAgentColorKey;
  bool _autoCompact = true;
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
      _selectedModel = existing.model.isEmpty ? null : existing.model;
      _contextLengthController.text = existing.maxContextLength.toString();
      _iconKey = existing.iconKey;
      _colorKey = existing.colorKey;
      _autoCompact = existing.autoCompact;
      _loadWorkspacePath(existing.id, agentName: existing.name);
    }
  }

  Future<void> _loadWorkspacePath(String agentId, {String? agentName}) async {
    final path = await ref
        .read(workspaceServiceProvider)
        .getWorkspacePath(agentId, agentName: agentName);
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s.pleaseSelectProvider)));
      return;
    }
    setState(() => _saving = true);
    try {
      final maxCtx = int.tryParse(_contextLengthController.text.trim()) ?? 8191;
      final agent = AgentModel(
        id: _existingId,
        name: _nameController.text.trim(),
        providerId: _selectedProviderId!,
        model: _resolvedSelectedModel(
          ref.read(providerListProvider).value ?? [],
        ),
        maxContextLength: maxCtx.clamp(512, 1000000),
        autoCompact: _autoCompact,
        iconKey: _iconKey,
        colorKey: _colorKey,
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
      final providers = ref.read(providerListProvider).value ?? [];
      final selectedProvider = providers
          .where((p) => p.id == result)
          .firstOrNull;
      setState(() {
        _selectedProviderId = selectedProvider != null ? result : _selectedProviderId;
        _selectedModel = selectedProvider?.models.firstOrNull;
      });
    }
  }

  String? _selectedModelFor(List<ProviderConfig> providers) {
    final provider = providers
        .where((p) => p.id == _selectedProviderId)
        .firstOrNull;
    if (provider == null) return null;
    final selected = (_selectedModel ?? '').trim();
    if (selected.isNotEmpty && provider.models.contains(selected)) {
      return selected;
    }
    return null;
  }

  List<MeowDropdownOption<String>> _modelOptionsFor(
    List<ProviderConfig> providers,
  ) {
    final provider = providers
        .where((p) => p.id == _selectedProviderId)
        .firstOrNull;
    if (provider == null) return const [];
    return provider.models
        .map((model) => MeowDropdownOption<String>(value: model, label: model))
        .toList();
  }

  String _resolvedSelectedModel(List<ProviderConfig> providers) {
    final provider = providers
        .where((p) => p.id == _selectedProviderId)
        .firstOrNull;
    if (provider == null) return _selectedModel ?? '';
    final selected = (_selectedModel ?? '').trim();
    return provider.models.contains(selected) ? selected : '';
  }

  Future<void> _confirmDelete() async {
    final isId = resolveLanguageCode(ref.read(appLanguageProvider)) == 'id';
    final confirmed = await showMeowConfirmDialog(
      context,
      isId: isId,
      title: s.deleteAgent,
      message: s.deleteAgentBody,
      confirmLabel: s.delete,
      cancelLabel: s.cancel,
    );

    if (confirmed && mounted) {
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
          error: (e, _) => Center(child: Text(s.errorWithMessage('$e'))),
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
                        border: Border.all(
                          color: extras.subtleBorder,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.folder_outlined,
                                      size: 18,
                                      color: cs.primary,
                                    ),
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
              const SizedBox(height: 16),

              // Agent profile section (Soul/Memory/Heartbeat).
              _AgentProfileSection(
                agentId: widget.agentId!,
                agentName: _nameController.text.isNotEmpty
                    ? _nameController.text
                    : 'Agent',
                isId: s.isId,
              ),
              const SizedBox(height: 24),
            ],

            // Agent name section.
            MeowSection(
              title: s.agentSection,
              subtitle: s.agentSectionDesc,
              bottomSpacing: 24,
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

            // Appearance section — collapsible "Personalize Agent" card.
            _AppearanceSection(
              iconKey: _iconKey,
              colorKey: _colorKey,
              isId: s.isId,
              onIconChanged: (k) => setState(() => _iconKey = k),
              onColorChanged: (k) => setState(() => _colorKey = k),
            ),
            const SizedBox(height: 24),

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
                  const SizedBox(height: 16),
                  if (providers.isEmpty)
                    _ProviderEmptyState(s: s)
                  else ...[
                    // Provider dropdown — single source of border via MeowDropdown.
                    MeowDropdown<String>(
                      label: s.selectProvider,
                      hint: s.chooseProvider,
                      sheetTitle: s.selectProvider,
                      value: providers.any((p) => p.id == _selectedProviderId)
                          ? _selectedProviderId
                          : null,
                      options: providers
                          .map(
                            (p) => MeowDropdownOption<String>(
                              value: p.id,
                              label: p.nickname,
                              subtitle: s.providerModelsCount(p.models.length),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        final selectedProvider = providers
                            .where((p) => p.id == v)
                            .firstOrNull;
                        setState(() {
                          _selectedProviderId = v;
                          _selectedModel = selectedProvider?.models.firstOrNull;
                        });
                      },
                    ),
                    const SizedBox(height: 14),
                    MeowDropdown<String>(
                      label: s.model,
                      hint: s.chooseModel,
                      sheetTitle: s.model,
                      value: _selectedModelFor(providers),
                      options: _modelOptionsFor(providers),
                      onChanged: (v) => setState(() => _selectedModel = v),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Advanced settings stay collapsed so the core setup flow breathes.
            _AdvancedAgentSettings(
              contextLengthController: _contextLengthController,
              autoCompact: _autoCompact,
              isId: s.isId,
              onAutoCompactChanged: (v) => setState(() => _autoCompact = v),
            ),
            const SizedBox(height: 20),

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

            // Delete button (edit mode only) — banner-style with cs.error.
            if (widget.agentId != null) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextButton(
                  onPressed: _confirmDelete,
                  style: TextButton.styleFrom(
                    foregroundColor: cs.error,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.delete_outline_rounded,
                        size: 18,
                        color: cs.error,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        s.deleteAgent,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: cs.error,
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

class _AdvancedAgentSettings extends StatefulWidget {
  const _AdvancedAgentSettings({
    required this.contextLengthController,
    required this.autoCompact,
    required this.isId,
    required this.onAutoCompactChanged,
  });

  final TextEditingController contextLengthController;
  final bool autoCompact;
  final bool isId;
  final ValueChanged<bool> onAutoCompactChanged;

  @override
  State<_AdvancedAgentSettings> createState() => _AdvancedAgentSettingsState();
}

class _AdvancedAgentSettingsState extends State<_AdvancedAgentSettings> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings(widget.isId ? 'id' : 'en');
    final cs = context.cs;
    final extras = context.extras;
    final title = s.advanced;
    final subtitle = s.advancedSubtitle(
      widget.contextLengthController.text,
      widget.autoCompact,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        decoration: BoxDecoration(
          color: extras.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: extras.subtleBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Icon(
                          Icons.tune_rounded,
                          size: 18,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _expanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Divider(height: 1, color: extras.subtleBorder),
                          const SizedBox(height: 16),
                          _AdvancedLabel(
                            title: s.maxContextLength,
                            subtitle: s.tokenLimitHint,
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: widget.contextLengthController,
                            keyboardType: TextInputType.number,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: cs.onSurface,
                            ),
                            decoration: InputDecoration(
                              hintText: '8191',
                              suffixText: 'tokens',
                              filled: true,
                              fillColor: extras.inputFill,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 13,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(
                                  color: extras.inputBorder,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(
                                  color: extras.inputBorder,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(
                                  color: extras.inputFocusBorder,
                                ),
                              ),
                            ),
                            validator: (v) {
                              final n = int.tryParse(v ?? '');
                              if (n == null || n < 512) {
                                return s.minTokens;
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: _AdvancedLabel(
                                  title: s.autoCompactContext,
                                  subtitle: s.autoCompactContextDesc,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Switch(
                                value: widget.autoCompact,
                                onChanged: widget.onAutoCompactChanged,
                              ),
                            ],
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdvancedLabel extends StatelessWidget {
  const _AdvancedLabel({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurfaceVariant,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

/// Collapsible "Personalize Agent" card keeps the form clean by hiding the
/// icon/color picker behind a tap-to-expand affordance.
class _AppearanceSection extends StatefulWidget {
  const _AppearanceSection({
    required this.iconKey,
    required this.colorKey,
    required this.isId,
    required this.onIconChanged,
    required this.onColorChanged,
  });

  final String iconKey;
  final String colorKey;
  final bool isId;
  final ValueChanged<String> onIconChanged;
  final ValueChanged<String> onColorChanged;

  @override
  State<_AppearanceSection> createState() => _AppearanceSectionState();
}

class _AppearanceSectionState extends State<_AppearanceSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings(widget.isId ? 'id' : 'en');
    final cs = context.cs;
    final extras = context.extras;
    final selectedColor = resolveAgentColor(widget.colorKey);
    final selectedIcon = resolveAgentIcon(widget.iconKey);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        decoration: BoxDecoration(
          color: extras.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: extras.subtleBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Tappable header.
            Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: selectedColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          selectedIcon,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              s.personalizeAgent,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface,
                                letterSpacing: -0.1,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s.chooseIconAndColor,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Expandable body.
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _expanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Divider(height: 1, color: extras.subtleBorder),
                          const SizedBox(height: 14),

                          // Icon picker.
                          _PickerLabel(
                            label: s.iconLabel,
                            cs: cs,
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 48,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: kAgentIconOptions.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (_, i) {
                                final opt = kAgentIconOptions[i];
                                final selected = opt.key == widget.iconKey;
                                return GestureDetector(
                                  onTap: () => widget.onIconChanged(opt.key),
                                  child: Container(
                                    width: 48,
                                    height: 48,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? selectedColor.withValues(
                                              alpha: 0.14,
                                            )
                                          : extras.inputFill,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: selected
                                            ? selectedColor.withValues(
                                                alpha: 0.55,
                                              )
                                            : extras.subtleBorder,
                                        width: selected ? 1.5 : 1,
                                      ),
                                    ),
                                    child: Icon(
                                      opt.icon,
                                      size: 20,
                                      color: selected
                                          ? selectedColor
                                          : cs.onSurfaceVariant,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),

                          const SizedBox(height: 14),

                          // Color picker — no glow; selection ring only.
                          _PickerLabel(
                            label: s.colorLabel,
                            cs: cs,
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 40,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: kAgentColorOptions.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 10),
                              itemBuilder: (_, i) {
                                final opt = kAgentColorOptions[i];
                                final selected = opt.key == widget.colorKey;
                                return GestureDetector(
                                  onTap: () => widget.onColorChanged(opt.key),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 150),
                                    width: 40,
                                    height: 40,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: opt.color,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: selected
                                            ? Colors.white
                                            : Colors.transparent,
                                        width: 2,
                                      ),
                                    ),
                                    child: selected
                                        ? const Icon(
                                            Icons.check_rounded,
                                            color: Colors.white,
                                            size: 18,
                                          )
                                        : null,
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small uppercase-leaning section label inside the personalize card.
class _PickerLabel extends StatelessWidget {
  const _PickerLabel({required this.label, required this.cs});

  final String label;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: cs.onSurfaceVariant,
        letterSpacing: 0.4,
      ),
    );
  }
}

/// Collapsible "Agent Profile" section in agent edit screen.
/// Shows profile tiles backed by SQLite repositories.
class _AgentProfileSection extends ConsumerStatefulWidget {
  const _AgentProfileSection({
    required this.agentId,
    required this.agentName,
    required this.isId,
  });

  final String agentId;
  final String agentName;
  final bool isId;

  @override
  ConsumerState<_AgentProfileSection> createState() =>
      _AgentProfileSectionState();
}

class _AgentProfileSectionState extends ConsumerState<_AgentProfileSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings(widget.isId ? 'id' : 'en');
    final cs = context.cs;
    final extras = context.extras;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        decoration: BoxDecoration(
          color: extras.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: extras.subtleBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Tappable header.
            Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Icon(
                          Icons.psychology_rounded,
                          size: 18,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.agentProfileSection,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s.agentProfileSectionDesc,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Expandable body.
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _expanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Column(
                        children: [
                          Divider(height: 1, color: extras.subtleBorder),
                          const SizedBox(height: 12),
                          _ProfileTile(
                            icon: Icons.face_rounded,
                            title: s.agentSoulTitle,
                            subtitle: s.agentSoulDesc,
                            cs: cs,
                            extras: extras,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => AgentSoulEditorScreen(
                                  agentId: widget.agentId,
                                  agentName: widget.agentName,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          _ProfileTile(
                            icon: Icons.memory_rounded,
                            title: s.agentMemoryTitle,
                            subtitle: s.agentMemoryDesc,
                            cs: cs,
                            extras: extras,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => AgentMemoryEditorScreen(
                                  agentId: widget.agentId,
                                  agentName: widget.agentName,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          _ProfileTile(
                            icon: Icons.monitor_heart_outlined,
                            title: s.agentHeartbeatTitle,
                            subtitle: s.agentHeartbeatDesc,
                            cs: cs,
                            extras: extras,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => AgentHeartbeatScreen(
                                  agentId: widget.agentId,
                                  agentName: widget.agentName,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Individual clickable row tile within the Agent Profile section.
class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.cs,
    required this.extras,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final ColorScheme cs;
  final MeowExtras extras;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: extras.subtleBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 17, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
