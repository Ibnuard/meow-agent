import 'language_detector.dart';
import 'language_registry.dart';

/// Records why a previous attempt failed so the next reflection can avoid
/// repeating it.
class RecoveryAttempt {
  const RecoveryAttempt({
    required this.reason,
    required this.failedToolName,
    this.failedArgsSummary = '',
    this.unverifiedEntity = '',
    this.unverifiedEntityType = '',
  });

  /// Short, English, machine-friendly reason. Examples:
  /// - `tool_failed`
  /// - `verification_unverified`
  /// - `stuck_loop`
  final String reason;

  /// The tool that failed.
  final String failedToolName;

  /// One-line summary of the args used (so the next attempt can avoid
  /// retrying with identical args).
  final String failedArgsSummary;

  /// Set when the attempt failed because the post-execute probe couldn't
  /// confirm the expected entity in the snapshot.
  final String unverifiedEntity;
  final String unverifiedEntityType;

  Map<String, dynamic> toJson() => {
        'reason': reason,
        'failed_tool': failedToolName,
        if (failedArgsSummary.isNotEmpty) 'args_summary': failedArgsSummary,
        if (unverifiedEntity.isNotEmpty) 'unverified_entity': unverifiedEntity,
        if (unverifiedEntityType.isNotEmpty)
          'unverified_entity_type': unverifiedEntityType,
      };

  String toCompactString() {
    final parts = [
      'reason=$reason',
      'tool=$failedToolName',
      if (failedArgsSummary.isNotEmpty) 'args=$failedArgsSummary',
      if (unverifiedEntity.isNotEmpty)
        'unverified=$unverifiedEntity($unverifiedEntityType)',
    ];
    return parts.join(' · ');
  }
}

/// Decision returned by [RecoveryCoordinator.evaluate].
enum RecoveryDecision {
  /// No recovery needed — the failure is unrecoverable or out of budget.
  giveUp,

  /// Re-reflect with the failure context appended; replan; resume execution.
  /// Engine should call reflector.reflect again, then planner.plan, then
  /// resume `_executeLoop` with the new plan.
  rethinkAndReplan,

  /// Same plan, just retry the next step. Used when the failure was a
  /// transient one-off and re-reflection would be overkill.
  retrySameStep,
}

/// Stateful coordinator that decides whether the runtime should re-reflect
/// after a failure (or stuck loop) instead of giving up.
///
/// Lifecycle:
/// 1. Engine calls [recordAttemptFailure] when reviewer returns `failed`,
///    when the post-execute validator returns `unverified`, or when
///    [StuckDetector] fires.
/// 2. Engine calls [evaluate] to ask: "should I re-reflect?"
/// 3. If [RecoveryDecision.rethinkAndReplan], engine re-invokes reflector +
///    planner with the failure context, then continues.
///
/// Budget: configurable max attempts (default 2). Once exceeded, the next
/// failure forces [RecoveryDecision.giveUp] with a localized message.
class RecoveryCoordinator {
  RecoveryCoordinator({this.maxAttempts = 2});

  /// Maximum re-reflection attempts within a single user turn.
  final int maxAttempts;

  final List<RecoveryAttempt> _attempts = [];

  /// All recorded failures so the reflector can see prior approaches.
  List<RecoveryAttempt> get attempts => List.unmodifiable(_attempts);

  int get attemptCount => _attempts.length;

  bool get isExhausted => _attempts.length >= maxAttempts;

  /// Reset state. Called at the start of each user turn.
  void reset() => _attempts.clear();

  /// Record a failed attempt before evaluating recovery.
  void recordAttemptFailure(RecoveryAttempt attempt) {
    _attempts.add(attempt);
  }

  /// Decide what the engine should do next.
  ///
  /// Returns:
  /// - [RecoveryDecision.rethinkAndReplan] when there's budget left AND
  ///   the failure pattern suggests a different approach might work.
  /// - [RecoveryDecision.retrySameStep] when only one identical retry is
  ///   warranted (e.g. snapshot stale on first try).
  /// - [RecoveryDecision.giveUp] when the budget is exhausted or the
  ///   failure is structural (e.g. permission denied — rethinking won't
  ///   change that).
  RecoveryDecision evaluate({
    bool failureIsStructural = false,
    bool snapshotMaybeStale = false,
  }) {
    if (failureIsStructural) return RecoveryDecision.giveUp;
    if (isExhausted) return RecoveryDecision.giveUp;

    // First attempt + snapshot likely stale → cheap retry once.
    if (_attempts.length == 1 && snapshotMaybeStale) {
      return RecoveryDecision.retrySameStep;
    }

    // If the same tool failed twice in a row with the same root cause,
    // re-reflection is unlikely to help unless we change strategy.
    if (_attempts.length >= 2 && _isRepeatingSameFailure()) {
      return RecoveryDecision.giveUp;
    }

    return RecoveryDecision.rethinkAndReplan;
  }

  /// Build a prompt-ready summary the engine can append to the next
  /// reflector / planner call so the LLM knows what NOT to try again.
  String toReflectionContext() {
    if (_attempts.isEmpty) return '';
    final buf = StringBuffer()
      ..writeln(
        'PRIOR ATTEMPTS (${_attempts.length}/$maxAttempts) — do NOT repeat the same approach:',
      );
    for (var i = 0; i < _attempts.length; i++) {
      buf.writeln('  ${i + 1}. ${_attempts[i].toCompactString()}');
    }
    buf.writeln('Pick a different tool, different args, or break the goal '
        'into smaller subgoals.');
    return buf.toString().trim();
  }

  /// Structured form of the attempt history. Used by the reflector prompt
  /// builder which renders fields explicitly. Keeps the prompt deterministic
  /// across recovery turns.
  List<Map<String, dynamic>> toReflectionContextList() =>
      _attempts.map((a) => a.toJson()).toList(growable: false);

  /// Localized message for the user when we hand back control after
  /// exhausting recovery budget.
  String giveUpMessage(DetectedLanguage language) {
    final lastReason = _attempts.isEmpty ? 'unknown' : _attempts.last.reason;
    return LanguageRegistry.phrase(
      'recovery_giving_up',
      language.code,
      {'reason': _humanReadableReason(lastReason, language)},
    );
  }

  bool _isRepeatingSameFailure() {
    if (_attempts.length < 2) return false;
    final last = _attempts.last;
    final prev = _attempts[_attempts.length - 2];
    return last.failedToolName == prev.failedToolName &&
        last.reason == prev.reason &&
        last.failedArgsSummary == prev.failedArgsSummary;
  }

  String _humanReadableReason(String code, DetectedLanguage language) {
    // Short, neutral phrasing. Avoid technical jargon — the user reads this.
    final key = switch (code) {
      'tool_failed' => 'recovery_reason_tool_failed',
      'verification_unverified' => 'recovery_reason_verification_unverified',
      'stuck_loop' => 'recovery_reason_stuck_loop',
      _ => 'recovery_reason_unknown',
    };
    return LanguageRegistry.phrase(key, language.code);
  }
}
