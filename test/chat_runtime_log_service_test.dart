import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/features/chat/data/chat_runtime_log_service.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('ChatRuntimeLogService', () {
    late ChatRuntimeLogService service;

    setUp(() {
      service = ChatRuntimeLogService(overrideDbPath: inMemoryDatabasePath);
    });

    tearDown(() async {
      await service.close();
    });

    test('startRun records the command request', () async {
      await service.startRun(agentId: 'agent-1', userMessage: 'open calendar');

      final events = await service.loadLast('agent-1');

      expect(events, hasLength(1));
      expect(events.single.isUserRequest, true);
      expect(events.single.data?['message'], 'open calendar');
    });

    test('startRun keeps only the latest command for an agent', () async {
      await service.startRun(agentId: 'agent-1', userMessage: 'first command');
      await service.appendRawEvent(
        agentId: 'agent-1',
        type: 'state_change',
        message: 'Analyzing first command',
        data: {'state': 'analyzing'},
      );

      await service.startRun(agentId: 'agent-1', userMessage: 'second command');

      final events = await service.loadLast('agent-1');

      expect(events, hasLength(1));
      expect(events.single.data?['message'], 'second command');
    });

    test('appendEvent persists runtime event details', () async {
      await service.startRun(agentId: 'agent-1', userMessage: 'make a note');
      await service.appendEvent(
        agentId: 'agent-1',
        event: RuntimeEvent(
          type: 'tool_call',
          message: 'Calling tool: notes.create',
          data: {
            'name': 'notes.create',
            'args': {'title': 'Idea'},
            'risk': 'safe',
          },
        ),
      );

      final events = await service.loadLast('agent-1');

      expect(events, hasLength(2));
      expect(events.last.type, 'tool_call');
      expect(events.last.data?['name'], 'notes.create');
      expect(events.last.data?['args'], {'title': 'Idea'});
    });

    test('clear removes runtime log rows for the agent', () async {
      await service.startRun(agentId: 'agent-1', userMessage: 'debug this');
      await service.clear('agent-1');

      expect(await service.loadLast('agent-1'), isEmpty);
    });
  });
}
