import 'meow_agent_skill.dart';
import 'modules/app_skill.dart';
import 'modules/attachment_skill.dart';
import 'modules/calendar_skill.dart';
import 'modules/chat_skill.dart';
import 'modules/clipboard_skill.dart';
import 'modules/communication_skill.dart';
import 'modules/database_skill.dart';
import 'modules/device_skill.dart';
import 'modules/files_skill.dart';
import 'modules/miniapp_skill.dart';
import 'modules/notes_skill.dart';
import 'modules/notification_skill.dart';
import 'modules/system_skill.dart';
import 'modules/web_skill.dart';
import 'modules/workflow_skill.dart';
import 'predefined_skill.dart';

class PredefinedSkillRegistry {
  PredefinedSkillRegistry._();

  static const masterSkill = meowAgentMasterSkill;

  static const skills = <PredefinedSkill>[
    predefinedAppSkill,
    predefinedAttachmentSkill,
    predefinedCalendarSkill,
    predefinedChatSkill,
    predefinedClipboardSkill,
    predefinedCommunicationSkill,
    predefinedSystemSkill,
    predefinedDatabaseSkill,
    predefinedDeviceSkill,
    predefinedFilesSkill,
    predefinedMiniAppSkill,
    predefinedNotesSkill,
    predefinedNotificationSkill,
    predefinedWebSkill,
    predefinedWorkflowSkill,
  ];

  static const all = <PredefinedSkill>[masterSkill, ...skills];

  static final byId = <String, PredefinedSkill>{
    for (final skill in all) skill.id: skill,
  };

  static List<PredefinedSkill> resolve(Iterable<String> skillIds) {
    return [for (final id in skillIds) ?byId[id]];
  }

  static List<String> normalizeSkillIds(Iterable<Object?> rawSkillIds) {
    final out = <String>[];
    final seen = <String>{};
    for (final raw in rawSkillIds) {
      final id = raw?.toString().trim();
      if (id == null || id.isEmpty || seen.contains(id)) continue;
      if (!byId.containsKey(id) || id == masterSkill.id) continue;
      seen.add(id);
      out.add(id);
    }
    return out;
  }

  static List<String> skillIdsForToolGroups(Iterable<Object?> rawGroups) {
    final out = <String>[];
    final seen = <String>{};
    for (final raw in rawGroups) {
      final group = raw?.toString().trim().toLowerCase();
      if (group == null || group.isEmpty) continue;
      for (final skill in skills) {
        if (!skill.toolGroups.contains(group) || seen.contains(skill.id)) {
          continue;
        }
        seen.add(skill.id);
        out.add(skill.id);
      }
    }
    return out;
  }

  static Set<String> toolNamesForSkillIds(
    Iterable<Object?> rawSkillIds, {
    bool includeRelated = true,
  }) {
    final normalized = normalizeSkillIds(rawSkillIds);
    final ids = <String>{...normalized};
    if (includeRelated) {
      for (final skill in resolve(normalized)) {
        ids.addAll(normalizeSkillIds(skill.relatedSkillIds));
      }
    }
    return resolve(ids).expand((skill) => skill.toolNames).toSet();
  }

  static Set<String> toolGroupsForSkillIds(Iterable<Object?> rawSkillIds) {
    final normalized = normalizeSkillIds(rawSkillIds);
    return resolve(normalized).expand((skill) => skill.toolGroups).toSet();
  }

  static String analyzerIndexBlock() {
    return skills
        .map((skill) {
          final groups = skill.toolGroups.join(', ');
          final tools = skill.toolNames.take(6).join(', ');
          final more = skill.toolNames.length > 6 ? ', ...' : '';
          return '- ${skill.id}: ${skill.summary} '
              'tool_groups=[$groups]; key_tools=[$tools$more]';
        })
        .join('\n');
  }

  static String skillDetailBlock(Iterable<Object?> rawSkillIds) {
    return resolve(normalizeSkillIds(rawSkillIds))
        .map((skill) {
          final groups = skill.toolGroups.join(', ');
          final tools = skill.toolNames.join(', ');
          final useWhen = skill.useWhen.map((e) => '- $e').join('\n');
          final avoidWhen = skill.avoidWhen.map((e) => '- $e').join('\n');
          final examples = skill.examples.take(4).join('; ');
          return '''${skill.id} — ${skill.title}
Summary: ${skill.summary}
Tool groups: [$groups]
Tools: [$tools]
Use when:
$useWhen
Avoid when:
${avoidWhen.isEmpty ? '- No special exclusions.' : avoidWhen}
Examples: [$examples]''';
        })
        .join('\n\n');
  }
}
