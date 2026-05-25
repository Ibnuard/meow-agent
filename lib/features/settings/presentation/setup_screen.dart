import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../../services/llm/openai_compatible_client.dart';
import '../data/app_language_provider.dart';
import '../data/llm_provider_config.dart';
import '../data/settings_repository.dart';

/// Setup screen: collects agent provider config
/// (Base URL + API Key + Model) and persists it.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _baseUrlController =
      TextEditingController(text: 'https://api.openai.com/v1');
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController(text: 'gpt-4.1-mini');

  bool _obscureKey = true;
  bool _testing = false;
  bool _saving = false;
  String? _testResult;
  bool? _testSuccess;

  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  LlmProviderConfig _buildConfig() => LlmProviderConfig(
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
    final client = OpenAiCompatibleClient();
    final ok = await client.testConnection(_buildConfig());
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
      await ref.read(masterAgentProvider.notifier).save(_buildConfig());
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

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.setupNewAgent),
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 40),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Intro card.
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
                          child: Icon(
                            Icons.auto_awesome_rounded,
                            color: cs.primary,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'New Agent',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: cs.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                s.newAgentDesc,
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

                // Provider section.
                MeowSection(
                  title: s.providerSection,
                  subtitle: s.providerSetupSubtitle,
                  child: Column(
                    children: [
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
                      MeowInput(
                        controller: _modelController,
                        label: s.model,
                        hint: 'gpt-4.1-mini',
                        validator: (v) {
                          if ((v ?? '').trim().isEmpty) {
                            return s.modelRequired;
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),

                // Test result banner.
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

                // Action buttons.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: MeowSecondaryButton(
                          label: _testing ? s.testing : s.test,
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
                          label: _saving ? s.saving : s.saveAndContinue,
                          icon: Icons.check_rounded,
                          loading: _saving,
                          onPressed: _saving ? null : _save,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Privacy note.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    s.privacyNote,
                    style: TextStyle(
                      fontSize: 12,
                      color: extras.subtleText,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
