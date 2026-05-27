import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../settings/data/app_language_provider.dart';
import 'workflow_editor_screen.dart';
import 'workflow_templates.dart';

/// Browse pre-built workflow templates organized by category.
class WorkflowTemplatesScreen extends ConsumerStatefulWidget {
  const WorkflowTemplatesScreen({super.key});

  @override
  ConsumerState<WorkflowTemplatesScreen> createState() => _WorkflowTemplatesScreenState();
}

class _WorkflowTemplatesScreenState extends ConsumerState<WorkflowTemplatesScreen> {
  TemplateCategory? _selectedCategory;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final langPref = ref.watch(appLanguageProvider);
    final isId = resolveLanguageCode(langPref) == 'id';
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    final templates = _selectedCategory == null
        ? WorkflowTemplateRegistry.templates
        : WorkflowTemplateRegistry.byCategory(_selectedCategory!);

    return Scaffold(
      appBar: AppBar(
        title: Text(isId ? 'Template Workflow' : 'Workflow Templates'),
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            // Category filter chips.
            SizedBox(
              height: 50,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                children: [
                  _categoryChip(null, isId ? 'Semua' : 'All', cs),
                  ...TemplateCategory.values.map(
                    (c) => _categoryChip(c, _categoryLabel(c, isId), cs),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + bottomInset),
                itemCount: templates.length,
                itemBuilder: (_, i) => _templateCard(templates[i], cs, extras, isId),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _categoryChip(TemplateCategory? cat, String label, ColorScheme cs) {
    final selected = _selectedCategory == cat;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => setState(() => _selectedCategory = cat),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? cs.primary.withValues(alpha: 0.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.2),
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _templateCard(WorkflowTemplate tpl, ColorScheme cs, MeowExtras extras, bool isId) {
    return GestureDetector(
      onTap: () async {
        final result = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => WorkflowEditorScreen(template: tpl),
          ),
        );
        if (result == true && mounted) Navigator.pop(context, true);
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: extras.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: extras.subtleBorder),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(tpl.icon, style: const TextStyle(fontSize: 22)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isId ? tpl.titleId : tpl.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isId ? tpl.descriptionId : tpl.description,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.3),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (tpl.defaultSteps.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${tpl.defaultSteps.length} ${isId ? "langkah" : "steps"}',
                        style: TextStyle(fontSize: 10, color: cs.primary, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }

  String _categoryLabel(TemplateCategory c, bool isId) {
    switch (c) {
      case TemplateCategory.productivity:
        return isId ? 'Produktivitas' : 'Productivity';
      case TemplateCategory.monitoring:
        return isId ? 'Monitoring' : 'Monitoring';
      case TemplateCategory.communication:
        return isId ? 'Komunikasi' : 'Communication';
      case TemplateCategory.automation:
        return isId ? 'Otomatisasi' : 'Automation';
      case TemplateCategory.health:
        return isId ? 'Kesehatan' : 'Health';
    }
  }
}
