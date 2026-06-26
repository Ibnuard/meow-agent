import '../predefined_skill.dart';

const predefinedWorkflowSkill = PredefinedSkill(
  id: 'meow.workflow',
  title: 'Scheduled workflows',
  summary:
      'Create, list, read, update, delete, and toggle scheduled automations.',
  toolGroups: ['workflow'],
  toolNames: [
    'workflow.create',
    'workflow.create_from_template',
    'workflow.list_templates',
    'workflow.list',
    'workflow.read',
    'workflow.update',
    'workflow.delete',
    'workflow.toggle',
  ],
  useWhen: [
    'The user wants a scheduled or recurring automation.',
    'The user asks to inspect, edit, enable, disable, or delete workflows.',
    'The user wants to create a workflow from an available template.',
  ],
  avoidWhen: [
    'The user wants a one-time calendar event; use a calendar skill when it exists.',
    'The user wants immediate execution without scheduling; select the target action skill instead.',
  ],
  requiredContextKeys: ['workflow_templates', 'existing_workflows'],
  examples: [
    '"run this every morning" -> workflow.create.',
    '"create workflow from template" -> workflow.create_from_template.',
    '"list workflows" -> workflow.list.',
    '"show this workflow" -> workflow.read.',
    '"change the schedule" -> workflow.update.',
    '"turn off this workflow" -> workflow.toggle.',
    '"delete this workflow" -> workflow.delete.',
  ],
);
