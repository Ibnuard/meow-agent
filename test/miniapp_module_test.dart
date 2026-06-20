import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:meow_agent/core/storage/meow_database.dart';
import 'package:meow_agent/features/miniapp/miniapp_module_plugin.dart';
import 'package:meow_agent/services/agent_runtime/tool_router.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';
import 'package:meow_agent/services/agent_runtime/module_plugin.dart';
import 'package:meow_agent/features/modules/data/module_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Mini App Tools Registration', () {
    final router = ToolRouter();

    test('miniapp.list is registered correctly', () {
      final def = router.getDefinition('miniapp.list');
      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
      expect(def.isRetrieval, true);
    });

    test('miniapp.read is registered correctly', () {
      final def = router.getDefinition('miniapp.read');
      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
      expect(def.isRetrieval, true);
    });

    test('miniapp.patch is registered correctly', () {
      final def = router.getDefinition('miniapp.patch');
      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
      expect(def.isRetrieval, false);
    });

    test('miniapp.create is registered correctly', () {
      final def = router.getDefinition('miniapp.create');
      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
      expect(def.isRetrieval, false);
    });

    test('miniapp.delete is registered correctly', () {
      final def = router.getDefinition('miniapp.delete');
      expect(def, isNotNull);
      expect(def!.risk, 'sensitive');
      expect(def.requiresConfirmation, true);
      expect(def.isRetrieval, false);
    });
  });

  group('Mini App Tool Executions', () {
    final plugin = MiniAppModulePlugin();
    final ctx = ModuleToolContext(
      agentName: '',
      agentId: '',
      moduleRepository: ModuleRepository(),
    );
    const appId = 'calorie_tracker';
    const originalCode = 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10';

    setUp(() async {
      final db = await MeowDatabase.instance.database;
      await db.delete('miniapps');
    });

    tearDown(() async {
      await MeowDatabase.instance.close();
    });

    test('can create, list, read (sliced), patch (slice content), and delete mini apps', () async {
      // 1. Initially list should be empty
      final listRes1 = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.list',
          args: {},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(listRes1.success, true);
      expect(listRes1.data!['apps'], isEmpty);

      // 2. Create a mini app
      final createRes = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.create',
          args: {
            'id': appId,
            'name': 'Calorie Tracker',
            'icon': 'local_fire_department',
            'codeHtml': originalCode,
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(createRes.success, true);
      expect(createRes.data!['id'], appId);
      expect(createRes.data!['created'], true);

      // 3. List should now have 1 item
      final listRes2 = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.list',
          args: {},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(listRes2.success, true);
      expect(listRes2.data!['apps'].length, 1);
      expect(listRes2.data!['apps'][0]['id'], appId);

      // 4. Read entire mini app
      final readResAll = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.read',
          args: {'id': appId},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(readResAll.success, true);
      expect(readResAll.data!['codeHtml'], originalCode);
      expect(readResAll.data!['totalLines'], 10);
      expect(readResAll.data!['startLine'], 1);
      expect(readResAll.data!['endLine'], 10);

      // 5. Read sliced mini app (lines 3 to 6)
      final readResSlice = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.read',
          args: {
            'id': appId,
            'startLine': 3,
            'endLine': 6,
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(readResSlice.success, true);
      expect(readResSlice.data!['codeHtml'], 'line3\nline4\nline5\nline6');
      expect(readResSlice.data!['totalLines'], 10);
      expect(readResSlice.data!['startLine'], 3);
      expect(readResSlice.data!['endLine'], 6);

      // 6. Patch specific range (replace lines 3 to 5)
      final patchRes = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.patch',
          args: {
            'id': appId,
            'startLine': 3,
            'endLine': 5,
            'targetContent': 'line3\nline4\nline5',
            'replacementContent': 'patched3\npatched4\npatched5',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(patchRes.success, true);
      expect(patchRes.data!['patched'], true);

      // 7. Verify the patch using read
      final readResPatched = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.read',
          args: {'id': appId},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(readResPatched.success, true);
      expect(
        readResPatched.data!['codeHtml'],
        'line1\nline2\npatched3\npatched4\npatched5\nline6\nline7\nline8\nline9\nline10',
      );
      expect(readResPatched.data!['totalLines'], 10);

      // 8. Patch with mismatched targetContent should fail
      final patchResFail1 = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.patch',
          args: {
            'id': appId,
            'startLine': 3,
            'endLine': 5,
            'targetContent': 'wrong_content',
            'replacementContent': 'new_content',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(patchResFail1.success, false);
      expect(patchResFail1.error, contains('not found'));

      // 9. Patch with out-of-bounds range should fail
      final patchResFail2 = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.patch',
          args: {
            'id': appId,
            'startLine': 5,
            'endLine': 15,
            'targetContent': 'line5',
            'replacementContent': 'new_content',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(patchResFail2.success, false);
      expect(patchResFail2.error, contains('out of bounds'));

      // 10. Delete the mini app
      final deleteRes = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.delete',
          args: {'id': appId},
          risk: 'sensitive',
          requiresConfirmation: true,
        ),
        ctx,
      );
      expect(deleteRes.success, true);
      expect(deleteRes.data!['id'], appId);
      expect(deleteRes.data!['deleted'], true);
    });

    test('automatically formats single-line HTML on read/create and updates database', () async {
      const singleLineCode = '<html><head><style>body{color:red;margin:0}</style></head><body><h1>Hello</h1></body></html>';
      
      // 1. Create a mini app with single-line code
      final createRes = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.create',
          args: {
            'id': 'format_test',
            'name': 'Format Test',
            'icon': 'widgets',
            'codeHtml': singleLineCode,
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(createRes.success, true);

      // 2. Read back the mini app and check that it was formatted
      final readRes = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.read',
          args: {'id': 'format_test'},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(readRes.success, true);
      
      final codeHtml = readRes.data!['codeHtml'] as String;
      expect(codeHtml.contains('\n'), true);
      expect(readRes.data!['totalLines'] > 2, true);
      
      // The CSS block body{color:red;margin:0} should be formatted with newlines
      expect(codeHtml, contains('body{\ncolor:red;\nmargin:0\n}\n'));
    });
  });
}
