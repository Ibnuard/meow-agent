import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'calendar_tools.dart';

/// Calendar module: event CRUD, agenda, conflict/free-slot queries, note links.
class CalendarModulePlugin extends ModulePlugin {
  const CalendarModulePlugin();

  @override
  String get moduleId => 'calendar';

  @override
  String get catalogGroup => 'calendar';

  @override
  List<String> get capabilityHints => const [
    'calendar',
    'event',
    'schedule',
    'reminder',
    'meeting',
    'appointment',
    'agenda',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'calendar.create',
      description: 'Create a new calendar event.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'title': 'string (required)',
        'startTime': 'ISO8601 string (required)',
        'endTime': 'ISO8601 string (optional, defaults +1h)',
        'description': 'string (optional)',
        'allDay': 'bool (optional, default false)',
        'color': 'string (optional, hex)',
        'tags': 'list<string> (optional)',
      },
      operation: 'create',
      targetEntity: 'calendar_event',
      selectorArgs: ['title'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'calendar_event',
        expectedDataKeys: ['eventId'],
      ),
    ),
    ToolDefinition(
      name: 'calendar.today',
      description: "Get today's calendar events.",
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'calendar.list',
      description: 'List calendar events within a date range.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'from': 'ISO8601 string (required)',
        'to': 'ISO8601 string (required)',
        'limit': 'int (optional, default 20)',
      },
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'calendar.read',
      description: 'Read a single calendar event by ID.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'eventId': 'string (required)'},
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'calendar.update',
      description: 'Update an existing calendar event.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'eventId': 'string (required)',
        'title': 'string (optional)',
        'description': 'string (optional)',
        'startTime': 'ISO8601 (optional)',
        'endTime': 'ISO8601 (optional)',
        'allDay': 'bool (optional)',
        'color': 'string (optional)',
        'tags': 'list<string> (optional)',
      },
      operation: 'update',
      targetEntity: 'calendar_event',
      selectorArgs: ['eventId'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'calendar_event',
        expectedDataKeys: ['updated'],
      ),
    ),
    ToolDefinition(
      name: 'calendar.delete',
      description: 'Delete a calendar event. Requires confirmation.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'eventId': 'string (required)'},
      operation: 'delete',
      targetEntity: 'calendar_event',
      selectorArgs: ['eventId'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'calendar_event',
        expectedDataKeys: ['deleted'],
      ),
    ),
    ToolDefinition(
      name: 'calendar.upcoming',
      description:
          'Agenda view: list upcoming events grouped by date for the next N days. Default 7 days.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'days': 'int (optional, 1-90, default 7)'},
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'calendar.conflicts',
      description:
          'Check whether a proposed time slot overlaps with existing events. Returns list of conflicting events.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'startTime': 'string (required, ISO8601)',
        'durationMinutes': 'int (optional, default 60)',
      },
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'calendar.free_slot',
      description:
          'Find available time slots of given duration within working hours. Use when user asks to find free time / when am I free.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'durationMinutes': 'int (optional, default 60)',
        'withinDays': 'int (optional, 1-30, default 7)',
        'dayStartHour': 'int (optional, 0-23, default 9)',
        'dayEndHour': 'int (optional, 1-24, default 17)',
        'maxResults': 'int (optional, 1-20, default 5)',
      },
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'calendar.link_note',
      description:
          'Associate a note with a calendar event (meeting notes pattern). Stored as note:<id> tag on the event.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'eventId': 'string (required)',
        'noteId': 'string (required)',
      },
      operation: 'update',
      targetEntity: 'calendar_event',
      selectorArgs: ['eventId'],
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) {
    final tools = CalendarTools(moduleRepository: ctx.moduleRepository);
    switch (request.name) {
      case 'calendar.create':
        return tools.executeCreate(request.args);
      case 'calendar.today':
        return tools.executeToday(request.args);
      case 'calendar.list':
        return tools.executeList(request.args);
      case 'calendar.read':
        return tools.executeRead(request.args);
      case 'calendar.update':
        return tools.executeUpdate(request.args);
      case 'calendar.delete':
        return tools.executeDelete(request.args);
      case 'calendar.upcoming':
        return tools.executeUpcoming(request.args);
      case 'calendar.conflicts':
        return tools.executeConflicts(request.args);
      case 'calendar.free_slot':
        return tools.executeFreeSlot(request.args);
      case 'calendar.link_note':
        return tools.executeLinkNote(request.args);
      default:
        return Future.value(
          ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'CalendarModulePlugin cannot handle ${request.name}',
          ),
        );
    }
  }
}
