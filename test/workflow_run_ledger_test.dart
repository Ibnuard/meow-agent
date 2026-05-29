import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:meow_agent/features/modules/workflows/workflow_run_ledger.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // ffi caches open databases by PATH. Using the shared ':memory:' path for
  // every test makes them collide in a full-suite run (writes and reads can
  // land on different cached handles). A unique file path per test guarantees
  // isolation.
  var seq = 0;
  String uniqueDbPath() {
    seq++;
    return '${Directory.systemTemp.path}/meow_run_${DateTime.now().microsecondsSinceEpoch}_$seq.db';
  }

  WorkflowRunLedger sampleRun({
    String workflowId = 'wf1',
    int stepCount = 2,
    WorkflowRunStatus status = WorkflowRunStatus.running,
  }) {
    final run = WorkflowRunLedger.start(
      workflowId: workflowId,
      workflowTitle: 'Morning Brief',
      agentId: 'agent_owner',
      steps: [
        for (var i = 0; i < stepCount; i++)
          WorkflowStepEntry(
            index: i,
            stepId: 'step_$i',
            // Each step may run as a different agent — the whole point of the
            // run-scoped ledger.
            agentId: 'agent_$i',
            agentName: 'Agent $i',
            mainGoal: 'do task $i',
          ),
      ],
    );
    run.status = status;
    return run;
  }

  group('WorkflowRunLedger model', () {
    test('isRunning reflects status', () {
      final run = sampleRun();
      expect(run.isRunning, true);
      run.status = WorkflowRunStatus.success;
      expect(run.isRunning, false);
    });

    test('json round-trip preserves steps and status', () {
      final run = sampleRun(stepCount: 3);
      run.currentStepIndex = 2;
      run.stepAt(0)!.status = WorkflowStepStatus.success;
      run.stepAt(0)!.result = 'done';
      run.stepAt(1)!.status = WorkflowStepStatus.blocked;
      run.stepAt(1)!.failureReason = 'needs sensitive permission: chat.send';

      final restored = WorkflowRunLedger.fromJson(run.toJson());
      expect(restored.runId, run.runId);
      expect(restored.workflowId, 'wf1');
      expect(restored.agentId, 'agent_owner');
      expect(restored.currentStepIndex, 2);
      expect(restored.steps.length, 3);
      expect(restored.stepAt(0)!.status, WorkflowStepStatus.success);
      expect(restored.stepAt(0)!.result, 'done');
      expect(restored.stepAt(1)!.status, WorkflowStepStatus.blocked);
      expect(restored.stepAt(1)!.agentId, 'agent_1');
      expect(
        restored.stepAt(1)!.failureReason,
        'needs sensitive permission: chat.send',
      );
    });

    test('status fromLabel handles unknown gracefully', () {
      expect(WorkflowRunStatusX.fromLabel(null), WorkflowRunStatus.running);
      expect(
        WorkflowRunStatusX.fromLabel('garbage'),
        WorkflowRunStatus.running,
      );
      expect(
        WorkflowRunStatusX.fromLabel('success'),
        WorkflowRunStatus.success,
      );
      expect(
        WorkflowRunStatusX.fromLabel('partial'),
        WorkflowRunStatus.partial,
      );
      expect(WorkflowRunStatusX.fromLabel('failed'), WorkflowRunStatus.failed);
    });

    test('step status fromLabel handles unknown gracefully', () {
      expect(WorkflowStepStatusX.fromLabel(null), WorkflowStepStatus.pending);
      expect(
        WorkflowStepStatusX.fromLabel('blocked'),
        WorkflowStepStatus.blocked,
      );
      expect(
        WorkflowStepStatusX.fromLabel('skipped'),
        WorkflowStepStatus.skipped,
      );
    });
  });

  group('WorkflowRunDatabase persistence', () {
    late WorkflowRunDatabase db;
    late String dbPath;

    setUp(() {
      dbPath = uniqueDbPath();
      db = WorkflowRunDatabase(overrideDbPath: dbPath);
    });

    tearDown(() async {
      await db.close();
      try {
        await File(dbPath).delete();
      } catch (_) {}
    });

    test('upsert + findById round-trip', () async {
      final run = sampleRun();
      await db.upsert(run);
      final found = await db.findById(run.runId);
      expect(found, isNotNull);
      expect(found!.runId, run.runId);
      expect(found.steps.length, 2);
    });

    test('listRunning returns only running runs', () async {
      final running = sampleRun(workflowId: 'wf_run');
      final done = sampleRun(
        workflowId: 'wf_done',
        status: WorkflowRunStatus.success,
      );
      await db.upsert(running);
      await db.upsert(done);

      final live = await db.listRunning();
      expect(live.length, 1);
      expect(live.first.runId, running.runId);
    });

    test('upsert replaces on same runId (live progress updates)', () async {
      final run = sampleRun();
      await db.upsert(run);

      run.currentStepIndex = 1;
      run.stepAt(1)!.status = WorkflowStepStatus.success;
      run.status = WorkflowRunStatus.success;
      run.finishedAt = DateTime.now();
      await db.upsert(run);

      final found = await db.findById(run.runId);
      expect(found!.currentStepIndex, 1);
      expect(found.status, WorkflowRunStatus.success);
      expect(found.stepAt(1)!.status, WorkflowStepStatus.success);
      expect(found.finishedAt, isNotNull);
    });

    test('listRecent returns runs newest-first', () async {
      await db.upsert(sampleRun(workflowId: 'a'));
      await db.upsert(
        sampleRun(workflowId: 'b', status: WorkflowRunStatus.failed),
      );
      final recent = await db.listRecent();
      expect(recent.length, 2);
    });
  });

  group('WorkflowRunDatabase stale-run sweep', () {
    test('sweepStaleRuns flips running rows to failed', () async {
      final dbPath = uniqueDbPath();
      final db = WorkflowRunDatabase(overrideDbPath: dbPath);
      try {
        final running = sampleRun(workflowId: 'wf_running');
        final done = sampleRun(
          workflowId: 'wf_done',
          status: WorkflowRunStatus.success,
        );
        await db.upsert(running);
        await db.upsert(done);

        final swept = await db.sweepStaleRuns();
        expect(swept, 1); // only the running row

        final found = await db.findById(running.runId);
        expect(found!.status, WorkflowRunStatus.failed);
        expect(found.finishedAt, isNotNull);

        // The already-terminal run is untouched.
        final stillDone = await db.findById(done.runId);
        expect(stillDone!.status, WorkflowRunStatus.success);

        expect(await db.listRunning(), isEmpty);
      } finally {
        await db.close();
        try {
          await File(dbPath).delete();
        } catch (_) {}
      }
    });
  });
}
