---
status: complete
priority: p2
issue_id: 109
tags: [code-review, flutter, cleanup, chat]
dependencies: []
---

# Dead `_PerformanceTrace` / `_PerfStub` stub — allocates `Stopwatch` objects on every update for zero benefit

## Problem Statement

`chat_message_providers.dart` contains `_PerformanceTrace`, `_PerfStub`, and a file-level `_perf` instance. `_PerformanceTrace.end()` starts a `Stopwatch` and immediately discards the elapsed time — it logs nothing, emits nothing, stores nothing. The two call sites allocate `Stopwatch` objects on every `loadSession` and every `_performMessageUpdate` call (up to 20/sec during streaming) for zero benefit. This is scaffolding for a performance tracing system that was never built.

## Findings

- **Source**: code-simplicity-reviewer (P2, confidence: 95)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart:25-40` (class definitions), lines ~361, 515, 1766, 1799 (call sites)
- **Evidence**:
  ```dart
  class _PerformanceTrace {
    final Stopwatch _stopwatch = Stopwatch()..start();
    void end({Map<String, dynamic>? additionalData}) {
      _stopwatch.stop();  // stops but discards result
    }
  }
  ```

## Proposed Solutions

### Solution A: Delete all three classes and both call sites (Recommended)
Remove `_PerformanceTrace`, `_PerfStub`, `_perf` declarations (~20 LOC) and the `trace.end(...)` calls at the two call sites.
- **Pros**: ~25 LOC removed; no Stopwatch allocations on hot paths
- **Cons**: If real tracing is added later, re-introduce at that time
- **Effort**: Trivial
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria

- [ ] No `_PerformanceTrace`, `_PerfStub`, or `_perf` references remain
- [ ] `flutter analyze` clean after removal

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
