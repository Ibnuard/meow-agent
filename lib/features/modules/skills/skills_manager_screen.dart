import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../../core/storage/agent_skills_repository.dart';
import '../../agents/data/agent_repository.dart';
import '../../settings/data/app_language_provider.dart';

class SkillsManagerScreen extends ConsumerWidget {
  const SkillsManagerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    final skillsAsync = ref.watch(agentSkillsStreamProvider);
    final agents = ref.watch(agentListProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.skillsManagerTitle),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/skills/new'),
        backgroundColor: cs.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.add_rounded, size: 28),
      ),
      body: SafeArea(
        child: skillsAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          error: (err, _) => Center(
            child: Text(s.errorWithMessage('$err')),
          ),
          data: (skills) {
            if (skills.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.psychology_outlined,
                        size: 64,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        s.skillsEmpty,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        s.skillsEmptyDesc,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: 180,
                        child: MeowPrimaryButton(
                          label: s.skillCreate,
                          onPressed: () => context.push('/skills/new'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
              itemCount: skills.length,
              separatorBuilder: (_, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final skill = skills[index];
                final assignedAgents = agents.where((a) => skill.assignedAgentIds.contains(a.id)).toList();

                return MeowCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => context.push('/skills/${skill.id}'),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  skill.title,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: cs.onSurface,
                                  ),
                                ),
                                if (skill.githubUrl != null && skill.githubUrl!.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    skill.githubUrl!,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: cs.primary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                                if (assignedAgents.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    children: [
                                      ...assignedAgents.take(2).map((agent) {
                                        return Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: cs.primary.withValues(alpha: 0.06),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: cs.primary.withValues(alpha: 0.12)),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              MeowAgentIcon(
                                                agent: agent,
                                                size: 12,
                                              ),
                                              const SizedBox(width: 3),
                                              Text(
                                                agent.name,
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w600,
                                                  color: cs.primary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      }),
                                      if (assignedAgents.length > 2)
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: cs.onSurface.withValues(alpha: 0.06),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: cs.onSurface.withValues(alpha: 0.12)),
                                          ),
                                          child: Text(
                                            '+${assignedAgents.length - 2} More',
                                            style: TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold,
                                              color: cs.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Switch(
                        value: skill.isEnabled,
                        activeThumbColor: cs.primary,
                        onChanged: (val) {
                          ref.read(agentSkillsRepositoryProvider).toggleEnabled(skill.id, val);
                        },
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
