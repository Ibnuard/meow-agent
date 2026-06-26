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
}
