import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../../features/settings/data/app_language_provider.dart';
import '../../../features/settings/data/llm_provider_config.dart';
import '../../../services/llm/openai_compatible_client.dart';
import '../../agents/data/agent_repository.dart';
import '../data/provider_config.dart';
import '../data/provider_repository.dart';

/// Screen to add or edit an LLM provider.
///
/// If [providerId] is null, creates a new provider.
/// If [providerId] is set, loads and edits the existing one.
class AddProviderScreen extends ConsumerStatefulWidget {
  const AddProviderScreen({super.key, this.providerId});

  final String? providerId;

  @override
  ConsumerState<AddProviderScreen> createState() => _AddProviderScreenState();
}

class _AddProviderScreenState extends ConsumerState<AddProviderScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nicknameController = TextEditingController();
  final _codenameController = TextEditingController();
  final _baseUrlController = TextEditingController(
    text: 'https://api.openai.com/v1',
  );
  final _apiKeyController = TextEditingController();
  final _modelInputController = TextEditingController();
  final List<String> _models = [];
  final Set<String> _visionModels = {};

  bool _obscureKey = true;
  bool _testing = false;
  bool _saving = false;
  String? _testResult;
  bool? _testSuccess;
  String? _existingId;

  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }

  @override
  void initState() {
    super.initState();
    if (widget.providerId != null) {
      _loadExisting();
    }
  }

  Future<void> _loadExisting() async {
    final providers = ref.read(providerListProvider).value ?? [];
    final existing = providers
        .where((p) => p.id == widget.providerId)
        .firstOrNull;
    if (existing != null) {
      _existingId = existing.id;
      _nicknameController.text = existing.nickname;
      _codenameController.text = existing.codename ?? '';
      _baseUrlController.text = existing.baseUrl;
      _apiKeyController.text = existing.apiKey;
      _models
        ..clear()
        ..addAll(existing.models);
      _visionModels
        ..clear()
        ..addAll(existing.visionModels);
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _codenameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelInputController.dispose();
    super.dispose();
  }

  ProviderConfig _buildConfig() => ProviderConfig(
    id: _existingId,
    nickname: _nicknameController.text.trim(),
    codename: _codenameController.text.trim().isEmpty ? null : _codenameController.text.trim().toUpperCase(),
    baseUrl: _baseUrlController.text.trim(),
    apiKey: _apiKeyController.text.trim(),
    model: _models.firstOrNull ?? '',
    models: _models,
    visionModels: _visionModels.toList(),
  );

  void _addModel() {
    final model = _modelInputController.text.trim();
    if (model.isEmpty || _models.contains(model)) return;
    setState(() {
      _models.add(model);
      _modelInputController.clear();
    });
    // Re-validate so the model error clears after adding a model.
    _formKey.currentState?.validate();
  }

  void _removeModel(String model) {
    if (_models.isEmpty) return;
    setState(() {
      _models.remove(model);
      _visionModels.remove(model);
    });
    // Re-validate so the model error appears if the list became empty.
    _formKey.currentState?.validate();
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _testing = true;
      _testResult = null;
      _testSuccess = null;
    });
    final config = _buildConfig();
    final client = OpenAiCompatibleClient();
    // Reuse the existing LlmProviderConfig-compatible test.
    final ok = await client.testConnection(_toLlmConfig(config));
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testSuccess = ok;
      _testResult = ok ? s.connectionOk : s.connectionFail;
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final config = _buildConfig();
      await ref.read(providerListProvider.notifier).save(config);
      if (!mounted) return;
      // Pop back, returning the saved provider id.
      context.pop(config.id);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete() async {
    final agents = ref.read(agentListProvider);
    final affectedAgents = agents
        .where((a) => a.providerId == widget.providerId)
        .toList();
    final isId = resolveLanguageCode(ref.read(appLanguageProvider)) == 'id';

    final affectedWarning = affectedAgents.isNotEmpty
        ? '\n\n${s.affectedAgentsWarning(affectedAgents.length)}\n'
              '${affectedAgents.map((a) => '• ${a.name}').join('\n')}'
        : '';

    final confirmed = await showMeowConfirmDialog(
      context,
      isId: isId,
      title: s.deleteProvider,
      message:
          '${s.deleteProviderBody(_nicknameController.text)}$affectedWarning',
      confirmLabel: s.delete,
      cancelLabel: s.cancel,
    );

    if (confirmed && mounted) {
      await ref.read(providerListProvider.notifier).delete(widget.providerId!);
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/providers');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final isEditing = widget.providerId != null;
    ref.watch(appLanguageProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? s.editProvider : s.addProvider),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 40),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Intro.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: MeowCard(
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          alignment: Alignment.center,
                          child: Icon(Icons.dns_rounded, color: cs.primary),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.llmProvider,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: cs.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                s.llmProviderDesc,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: cs.onSurfaceVariant,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // Fields.
                MeowSection(
                  title: s.providerDetails,
                  subtitle: s.providerDetailsDesc,
                  child: Column(
                    children: [
                      MeowInput(
                        controller: _nicknameController,
                        label: s.nickname,
                        hint: s.nicknameHint,
                        helper: s.nicknameHelper,
                        validator: (v) {
                          if ((v ?? '').trim().isEmpty) {
                            return s.nicknameRequired;
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 18),
                      MeowInput(
                        controller: _codenameController,
                        label: s.codename,
                        hint: s.codenameHint,
                        helper: s.codenameHelper,
                        maxLength: 4,
                        textCapitalization: TextCapitalization.characters,
                        validator: (v) {
                          final val = v?.trim() ?? '';
                          if (val.length > 4) return s.codenameTooLong;
                          return null;
                        },
                      ),
                      const SizedBox(height: 18),
                      MeowInput(
                        controller: _baseUrlController,
                        label: s.baseUrl,
                        hint: 'https://api.openai.com/v1',
                        keyboardType: TextInputType.url,
                        validator: (v) {
                          final value = v?.trim() ?? '';
                          if (value.isEmpty) return s.baseUrlRequired;
                          final uri = Uri.tryParse(value);
                          if (uri == null || !uri.hasScheme) {
                            return s.baseUrlInvalid;
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 18),
                      MeowInput(
                        controller: _apiKeyController,
                        label: s.apiKey,
                        hint: 'sk-...',
                        obscureText: _obscureKey,
                        helper: s.apiKeyHelper,
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setState(() => _obscureKey = !_obscureKey),
                          icon: Icon(
                            _obscureKey
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            size: 20,
                          ),
                        ),
                        validator: (v) {
                          if ((v ?? '').trim().isEmpty) {
                            return s.apiKeyRequired;
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 18),
                      _ModelListEditor(
                        models: _models,
                        controller: _modelInputController,
                        isId: s.isId,
                        onAdd: _addModel,
                        onRemove: _removeModel,
                      ),
                    ],
                  ),
                ),

                // Test result.
                if (_testResult != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: (_testSuccess ?? false)
                            ? extras.success.withValues(alpha: 0.1)
                            : cs.error.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: (_testSuccess ?? false)
                              ? extras.success.withValues(alpha: 0.4)
                              : cs.error.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            (_testSuccess ?? false)
                                ? Icons.check_circle_rounded
                                : Icons.error_outline_rounded,
                            color: (_testSuccess ?? false)
                                ? extras.success
                                : cs.error,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _testResult!,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Buttons.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: MeowSecondaryButton(
                          label: _testing ? s.testing : s.test,
                          icon: Icons.bolt_rounded,
                          loading: _testing,
                          onPressed: _testing || _saving
                              ? null
                              : _testConnection,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: MeowPrimaryButton(
                          label: _saving ? s.saving : s.saveProvider,
                          icon: Icons.check_rounded,
                          loading: _saving,
                          onPressed: _saving ? null : _save,
                        ),
                      ),
                    ],
                  ),
                ),

                // Delete button (edit mode only).
                if (widget.providerId != null) ...[
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
                            s.deleteProvider,
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
        ),
      ),
    );
  }
}

class _ModelListEditor extends FormField<List<String>> {
  _ModelListEditor({
    required List<String> models,
    required TextEditingController controller,
    required bool isId,
    required VoidCallback onAdd,
    required ValueChanged<String> onRemove,
  }) : super(
         initialValue: models,
         autovalidateMode: AutovalidateMode.onUserInteraction,
         validator: (_) {
           if (models.isEmpty) {
             return AppStrings(isId ? 'id' : 'en').modelListRequired;
           }
           return null;
         },
         builder: (state) {
           final s = AppStrings(isId ? 'id' : 'en');
           final extras = state.context.extras;
           final hasError = state.hasError;
           return Column(
             crossAxisAlignment: CrossAxisAlignment.start,
             children: [
               MeowInput(
                 controller: controller,
                 label: s.modelListLabel,
                 hint: s.modelListHint,
                 textInputAction: TextInputAction.done,
                 onSubmitted: (_) => onAdd(),
                 errorText: hasError ? state.errorText : null,
                 suffixIcon: Padding(
                   padding: const EdgeInsets.only(right: 8),
                   child: Center(
                     widthFactor: 1,
                     heightFactor: 1,
                     child: IconButton.filledTonal(
                       onPressed: onAdd,
                       icon: const Icon(Icons.add_rounded, size: 18),
                       style: IconButton.styleFrom(
                         minimumSize: const Size(36, 36),
                         maximumSize: const Size(36, 36),
                         padding: EdgeInsets.zero,
                       ),
                     ),
                   ),
                 ),
               ),
               const SizedBox(height: 12),
               Wrap(
                 spacing: 8,
                 runSpacing: 8,
                 children: [
                   for (final model in models)
                     _ModelChip(
                       model: model,
                       onRemove: () => onRemove(model),
                     ),
                 ],
               ),
               const SizedBox(height: 8),
               Text(
                 s.modelListHelper,
                 style: TextStyle(
                   fontSize: 12,
                   color: extras.subtleText,
                   height: 1.35,
                 ),
               ),
               const SizedBox(height: 18),
             ],
           );
         },
       );
}

class _ModelChip extends StatelessWidget {
  const _ModelChip({
    required this.model,
    required this.onRemove,
  });

  final String model;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 6, top: 7, bottom: 7),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            model,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onRemove,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bridge to the existing OpenAI client which expects LlmProviderConfig.
LlmProviderConfig _toLlmConfig(ProviderConfig p) =>
    LlmProviderConfig(baseUrl: p.baseUrl, apiKey: p.apiKey, model: p.model);
