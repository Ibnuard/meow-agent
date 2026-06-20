import 'package:flutter_test/flutter_test.dart';

import 'package:meow_agent/services/agent_runtime/execute_loop_runner.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';

ToolCallRequest _vm(String command) => ToolCallRequest(
  name: 'vm.run_command',
  args: {'command': command},
  risk: 'sensitive',
  requiresConfirmation: true,
);

void main() {
  group('isSetupOnlyToolCall — bare corrective commands', () {
    test('mkdir alone is setup-only', () {
      expect(
        ExecuteLoopRunner.isSetupOnlyToolCall(_vm('mkdir -p /root/workspace/BEJO')),
        isTrue,
      );
    });

    test('bare cd is setup-only', () {
      expect(
        ExecuteLoopRunner.isSetupOnlyToolCall(_vm('cd /root/workspace/BEJO')),
        isTrue,
      );
    });

    test('package install is setup-only', () {
      expect(
        ExecuteLoopRunner.isSetupOnlyToolCall(_vm('apt-get install -y nodejs')),
        isTrue,
      );
      expect(
        ExecuteLoopRunner.isSetupOnlyToolCall(_vm('npm i')),
        isTrue,
      );
    });

    test('chained mkdir-then-mkdir is still setup-only', () {
      expect(
        ExecuteLoopRunner.isSetupOnlyToolCall(_vm('mkdir -p a && cd a')),
        isTrue,
      );
    });
  });

  group('isSetupOnlyToolCall — productive commands are NOT setup-only', () {
    test('mkdir chained into the real scaffold is productive', () {
      expect(
        ExecuteLoopRunner.isSetupOnlyToolCall(
          _vm('mkdir -p /root/workspace/BEJO && npm create vite@latest . -- --template react'),
        ),
        isFalse,
      );
    });

    test('a bare scaffold command is productive', () {
      expect(
        ExecuteLoopRunner.isSetupOnlyToolCall(
          _vm('npm create vite@latest my-app -- --template react'),
        ),
        isFalse,
      );
    });

    test('non-shell tools are never setup-only', () {
      expect(
        ExecuteLoopRunner.isSetupOnlyToolCall(
          ToolCallRequest(
            name: 'vm.start_server',
            args: const {},
            risk: 'sensitive',
            requiresConfirmation: true,
          ),
        ),
        isFalse,
      );
    });

    test('empty command is not setup-only', () {
      expect(ExecuteLoopRunner.isSetupOnlyToolCall(_vm('')), isFalse);
    });
  });

  group('userGoalImpliesProductiveWork', () {
    test('scaffold + serve goal implies productive work', () {
      expect(
        ExecuteLoopRunner.userGoalImpliesProductiveWork(
          'Create a landing page with React, Vite, and Tailwind, then serve it on a dev server for the user to view.',
        ),
        isTrue,
      );
    });

    test('a build goal implies productive work', () {
      expect(
        ExecuteLoopRunner.userGoalImpliesProductiveWork('Build and run the project'),
        isTrue,
      );
    });

    test('a pure "make a folder" goal does NOT imply productive work', () {
      expect(
        ExecuteLoopRunner.userGoalImpliesProductiveWork('Create a folder named BEJO'),
        isFalse,
      );
    });

    test('an empty goal does NOT imply productive work', () {
      expect(ExecuteLoopRunner.userGoalImpliesProductiveWork(''), isFalse);
    });
  });

  group('extractFailureCause — surfaces the real cause to the user', () {
    test('uses result.error first line when present', () {
      final r = ToolExecutionResult(
        success: false,
        toolName: 'vm.run_command',
        error: '/bin/sh: 1: npx: not found\n',
        data: const {'success': false, 'exit_code': 127},
      );
      expect(
        ExecuteLoopRunner.extractFailureCause(r),
        '/bin/sh: 1: npx: not found',
      );
    });

    test('falls back to data.stderr when error is empty', () {
      final r = ToolExecutionResult(
        success: false,
        toolName: 'vm.run_command',
        error: '',
        data: const {
          'success': false,
          'stderr': 'ENOENT: no such file or directory\n  at fs.openSync',
        },
      );
      expect(
        ExecuteLoopRunner.extractFailureCause(r),
        'ENOENT: no such file or directory',
      );
    });

    test('falls back to data.message when error and stderr are empty', () {
      final r = ToolExecutionResult(
        success: false,
        toolName: 'something.do',
        error: null,
        data: const {'success': false, 'message': 'Permission denied'},
      );
      expect(
        ExecuteLoopRunner.extractFailureCause(r),
        'Permission denied',
      );
    });

    test('returns empty for null result', () {
      expect(ExecuteLoopRunner.extractFailureCause(null), '');
    });

    test('returns empty for successful result (never used)', () {
      final r = ToolExecutionResult(
        success: true,
        toolName: 'vm.status',
        data: const {'success': true},
      );
      expect(ExecuteLoopRunner.extractFailureCause(r), '');
    });

    test('returns empty when result has no extractable signal', () {
      final r = ToolExecutionResult(
        success: false,
        toolName: 'opaque.tool',
        error: '   ',
        data: const {'success': false},
      );
      expect(ExecuteLoopRunner.extractFailureCause(r), '');
    });

    test('does not invent or transform content — pure passthrough', () {
      const stderr = 'EACCES: permission denied, open \'/etc/hosts\'';
      final r = ToolExecutionResult(
        success: false,
        toolName: 'vm.write_file',
        error: stderr,
        data: const {'success': false, 'stderr': stderr},
      );
      // The cause is exactly the first line of what the handler emitted —
      // no rewording, no tool-name leak, no synthetic prefix.
      expect(ExecuteLoopRunner.extractFailureCause(r), stderr);
    });
  });

  group('targetFromArgs — stuck detector target extraction', () {
    test('extracts standard id or name field', () {
      expect(
        ExecuteLoopRunner.targetFromArgs(const {'id': 'my_app'}),
        'id=my_app',
      );
      expect(
        ExecuteLoopRunner.targetFromArgs(const {'name': 'Tester'}),
        'name=Tester',
      );
      expect(
        ExecuteLoopRunner.targetFromArgs(const {'path': '/some/path'}),
        'path=/some/path',
      );
    });

    test('appends range/slice/pagination bounds to prevent false positive stuck loops', () {
      expect(
        ExecuteLoopRunner.targetFromArgs(const {
          'id': 'my_app',
          'startLine': 100,
          'endLine': 200,
        }),
        'id=my_app|range:100_200',
      );

      expect(
        ExecuteLoopRunner.targetFromArgs(const {
          'id': 'my_app',
          'offset': 10,
          'limit': 50,
        }),
        'id=my_app|range:10_50',
      );

      // No range/slice keys present - fallback to pure target identifier
      expect(
        ExecuteLoopRunner.targetFromArgs(const {'id': 'my_app'}),
        'id=my_app',
      );
    });
  });
}
