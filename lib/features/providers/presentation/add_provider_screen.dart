import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
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
  final _baseUrlController =
      TextEditingController(text: 'https://api.openai.com/v1');
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController(text: 'gpt-4.1-mini');

  bool _obscureKey = true;
  bool _testing = false;
  bool _saving = false;
  String? _testResult;
  bool? _testSuccess;
  String? _existingId;

  @override
  void initState() {
    super.initState();
    if (widget.providerId != null) {
      _loadExisting();
    }
  }

  Future<void> _loadExisting() async {
    final providers = ref.read(providerListProvider).value ?? [];
    final existing = providers.where((p) => p.id == widget.providerId).firstOrNull;
    if (existing != null) {
      _existingId = existing.id;
      _nicknameController.text = existing.nickname;
      _baseUrlController.text = existing.baseUrl;
      _apiKeyController.text = existing.apiKey;
      _modelController.text = existing.model;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  ProviderConfig _buildConfig() => ProviderConfig(
        id: _existingId,
        nickname: _nicknameController.text.trim(),
        baseUrl: _baseUrlController.text.trim(),
        apiKey: _apiKeyController.text.trim(),
        model: _modelController.text.trim(),
      );

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
    final ok = await client.testConnection(
      _toLlmConfig(config),
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testSuccess = ok;
      _testResult = ok ? 'Connection successful' : 'Connection failed';
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
    final affectedAgents =
        agents.where((a) => a.providerId == widget.providerId).toList();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Provider'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Delete "${_nicknameController.text}"?\n\n'
              'This will remove the provider configuration and API key.',
            ),
            if (affectedAgents.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '⚠️ ${affectedAgents.length} agent(s) using this provider '
                'will lose their connection:',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              ...affectedAgents.map(
                (a) => Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Text('• ${a.name}'),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFF87171),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
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

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Provider' : 'Add Provider'),
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
                                'LLM Provider',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: cs.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Connect any OpenAI-compatible API endpoint.',
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
                  title: 'Provider Details',
                  subtitle: 'Give it a name and enter the connection info.',
                  child: Column(
                    children: [
                      MeowInput(
                        controller: _nicknameController,
                        label: 'Nickname',
                        hint: 'e.g. OpenAI, Groq, Local...',
                        helper: 'Shown in the agent provider dropdown.',
                        validator: (v) {
                          if ((v ?? '').trim().isEmpty) {
                            return 'Nickname is required';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 18),
                      MeowInput(
                        controller: _baseUrlController,
                        label: 'Base URL',
                        hint: 'https://api.openai.com/v1',
                        keyboardType: TextInputType.url,
                        validator: (v) {
                          final value = v?.trim() ?? '';
                          if (value.isEmpty) return 'Base URL is required';
                          final uri = Uri.tryParse(value);
                          if (uri == null || !uri.hasScheme) {
                            return 'Enter a valid URL (https://...)';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 18),
                      MeowInput(
                        controller: _apiKeyController,
                        label: 'API Key',
                        hint: 'sk-...',
                        obscureText: _obscureKey,
                        helper: 'Stored securely on this device only.',
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
                            return 'API Key is required';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 18),
                      MeowInput(
                        controller: _modelController,
                        label: 'Model',
                        hint: 'gpt-4.1-mini',
                        validator: (v) {
                          if ((v ?? '').trim().isEmpty) {
                            return 'Model is required';
                          }
                          return null;
                        },
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
                          horizontal: 16, vertical: 14),
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
                          label: _testing ? 'Testing...' : 'Test',
                          icon: Icons.bolt_rounded,
                          loading: _testing,
                          onPressed:
                              _testing || _saving ? null : _testConnection,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: MeowPrimaryButton(
                          label: _saving ? 'Saving...' : 'Save Provider',
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
                        foregroundColor: const Color(0xFFF87171),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.delete_outline_rounded, size: 18),
                          SizedBox(width: 8),
                          Text(
                            'Delete Provider',
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
        ),
      ),
    );
  }
}

/// Bridge to the existing OpenAI client which expects LlmProviderConfig.
LlmProviderConfig _toLlmConfig(ProviderConfig p) => LlmProviderConfig(
      baseUrl: p.baseUrl,
      apiKey: p.apiKey,
      model: p.model,
    );
