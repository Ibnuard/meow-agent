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
      expect(def.inputSchema, contains('app'));
    });

    test('miniapp.patch is registered correctly', () {
      final def = router.getDefinition('miniapp.patch');
      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
      expect(def.isRetrieval, false);
      expect(def.selectorArgs, contains('app'));
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
      expect(def.selectorArgs, contains('app'));
    });
  });

  group('Mini App Tool Executions', () {
    final plugin = MiniAppModulePlugin();
    final ctx = ModuleToolContext(agentName: '', agentId: '', moduleRepository: ModuleRepository());
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
          args: {'id': appId, 'startLine': 3, 'endLine': 6},
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

    test('resolves a user-facing name and patches without internal ID or line range', () async {
      const code = '''
<html>
<style>
.card {
  background: white;
}
</style>
<body class="card">Calories</body>
</html>
''';
      await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.create',
          args: {'id': 'calorie_tracker_internal', 'name': 'Kalkulator Kalori', 'codeHtml': code},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      final readResult = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.read',
          args: {'app': 'kalkulator-kalori'},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(readResult.success, true);
      expect(readResult.data!['id'], 'calorie_tracker_internal');
      expect(readResult.data!['name'], 'Kalkulator Kalori');

      final patchResult = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.patch',
          args: {
            'app': 'Kalkulator Kalori',
            'targetContent': '.card { background: white; }',
            'replacementContent': '.card { background: mintcream; }',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(patchResult.success, true);
      expect(patchResult.data!['id'], 'calorie_tracker_internal');
      expect(patchResult.data!['persisted'], true);

      final verifyResult = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.read',
          args: {'app': 'Kalkulator Kalori'},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(verifyResult.data!['codeHtml'], contains('background: mintcream'));
      expect(verifyResult.data!['codeHtml'], contains('<body class="card">'));
    });

    test('unknown display name returns structured installed app choices', () async {
      await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.create',
          args: {
            'id': 'calorie_tracker_internal',
            'name': 'Kalkulator Kalori',
            'codeHtml': '<p>Calories</p>',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      final result = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.read',
          args: {'app': 'Nutrition Dashboard'},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      expect(result.success, false);
      expect(result.error, contains('was not found'));
      expect(result.data!['available'], [
        {'id': 'calorie_tracker_internal', 'name': 'Kalkulator Kalori'},
      ]);
    });

    test('revision range patch replaces exact lines without echoing target content', () async {
      await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.create',
          args: {
            'id': 'revision_patch_test',
            'name': 'Revision Patch Test',
            'codeHtml': 'line1\nold layout\nline3',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      final read = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.read',
          args: {'app': 'Revision Patch Test'},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      final revision = read.data!['revision'] as String;

      final patch = await plugin.dispatch(
        ToolCallRequest(
          name: 'miniapp.patch',
          args: {
            'app': 'Revision Patch Test',
            'expectedRevision': revision,
            'startLine': 2,
            'endLine': 2,
            'replacementContent': 'new modern layout',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      expect(patch.success, true);
      expect(patch.data!['previousRevision'], revision);
      expect(patch.data!['revision'], isNot(revision));
      final verify = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.read',
          args: {'app': 'Revision Patch Test'},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(verify.data!['codeHtml'], 'line1\nnew modern layout\nline3');
    });

    test('revision range patch rejects stale reads without changing code', () async {
      final create = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.create',
          args: {
            'id': 'stale_patch_test',
            'name': 'Stale Patch Test',
            'codeHtml': 'before',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      final patch = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.patch',
          args: {
            'app': 'Stale Patch Test',
            'expectedRevision': 'stale-revision',
            'startLine': 1,
            'endLine': 1,
            'replacementContent': 'after',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      expect(patch.success, false);
      expect(patch.data!['staleRevision'], true);
      expect(patch.data!['currentRevision'], create.data!['revision']);
      final verify = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.read',
          args: {'app': 'Stale Patch Test'},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(verify.data!['codeHtml'], 'before');
    });

    test('create refuses to overwrite an existing Mini App', () async {
      await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.create',
          args: {
            'id': 'existing_app',
            'name': 'Existing App',
            'codeHtml': 'original',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      final overwrite = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.create',
          args: {
            'id': 'existing_app',
            'name': 'Existing App',
            'codeHtml': 'replacement',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      expect(overwrite.success, false);
      expect(overwrite.data!['existing'], true);
      expect(overwrite.data!['requiredTool'], 'miniapp.patch');
      final verify = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.read',
          args: {'app': 'Existing App'},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(verify.data!['codeHtml'], 'original');
    });

    test('automatically formats single-line HTML on read/create and updates database', () async {
      const singleLineCode =
          '<html><head><style>body{color:red;margin:0}</style></head><body><h1>Hello</h1></body></html>';

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

    test('whitespace normalization: agent natural CSS matches formatted storage', () async {
      // This simulates the real scenario: storage is formatted, agent writes natural CSS
      const htmlCode = '''
<style>
body{
color:red;
margin:0;
}
</style>
''';

      // 1. Create with pre-formatted code (as if from _formatHtml)
      await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.create',
          args: {
            'id': 'css_norm_test',
            'name': 'CSS Norm Test',
            'icon': '🎨',
            'codeHtml': htmlCode,
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      // 2. Agent writes NATURAL CSS (not matching internal formatting)
      final patchRes = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.patch',
          args: {
            'id': 'css_norm_test',
            'startLine': 2,
            'endLine': 5,
            'targetContent': 'body { color: red; margin: 0; }',
            'replacementContent': 'body { color: blue; margin: 0; }',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      // Should succeed — normalization handles whitespace differences
      expect(patchRes.success, true);
      expect(patchRes.data!['patched'], true);

      // Verify the change was applied correctly
      final readRes = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.read',
          args: {'id': 'css_norm_test'},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );
      expect(readRes.success, true);
      expect(readRes.data!['codeHtml'], contains('color:blue'));
    });

    test('whitespace normalization: multi-line JS block', () async {
      const htmlCode = '''
<script>
function init(){
console.log("hello");
return true;
}
</script>
''';

      await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.create',
          args: {'id': 'js_norm_test', 'name': 'JS Norm Test', 'icon': '⚡', 'codeHtml': htmlCode},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      // Agent writes natural JS (single line, different formatting)
      final patchRes = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.patch',
          args: {
            'id': 'js_norm_test',
            'startLine': 2,
            'endLine': 5,
            'targetContent': 'function init() { console.log("hello"); return true; }',
            'replacementContent': 'function init() { console.log("hello world"); return true; }',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      expect(patchRes.success, true);
      expect(patchRes.data!['patched'], true);
    });

    test('mismatch error includes hint and actual content', () async {
      await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.create',
          args: {
            'id': 'error_hint_test',
            'name': 'Error Hint Test',
            'icon': '❌',
            'codeHtml': '<style>\n.card {\n  background: white;\n  padding: 16px;\n}\n</style>',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      // Agent tries wrong targetContent
      final patchRes = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.patch',
          args: {
            'id': 'error_hint_test',
            'startLine': 2,
            'endLine': 4,
            'targetContent': '.button { background: red; }', // Wrong selector
            'replacementContent': '.button { background: blue; }',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      expect(patchRes.success, false);
      expect(patchRes.error, contains('ACTUAL CONTENT'));
      expect(patchRes.error, contains('HINT'));
      expect(patchRes.data!['hint'], contains('.card')); // CSS selector detected
      expect(patchRes.data!['id'], 'error_hint_test');
    });

    test('patch with same-format targetContent still works', () async {
      // Ensure we didn't break the exact-match path (it still works)
      await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.create',
          args: {
            'id': 'exact_match_test',
            'name': 'Exact Match Test',
            'icon': '✓',
            'codeHtml': '<style>\n.header {\n  color: green;\n}\n</style>',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      // Use EXACT text from storage (lines 2-4 = CSS block including closing brace)
      final patchRes = await plugin.dispatch(
        const ToolCallRequest(
          name: 'miniapp.patch',
          args: {
            'id': 'exact_match_test',
            'startLine': 2,
            'endLine': 4,
            'targetContent': '.header {\n  color: green;\n}',
            'replacementContent': '.header {\n  color: purple;\n}',
          },
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ctx,
      );

      expect(patchRes.success, true);
    });
  });
}
