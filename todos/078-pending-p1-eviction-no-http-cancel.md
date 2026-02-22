---
status: pending
priority: p1
issue_id: 79
tags: [code-review, flutter, resource-leak, streaming]
dependencies: []
---

# Eviction doesn't cancel source HTTP stream

## Problem Statement

When a stream is evicted in `BackgroundStreamManager._evictIfNeeded()`, only the broadcast `StreamController` is closed via `_ActiveStream.cancel()`. The source HTTP SSE stream subscription is not explicitly cancelled. While `_consumeStream` checks `controller.isClosed` and breaks, the `await for` loop must receive and process the next event before it checks the flag — meaning the HTTP connection stays open until the next SSE event arrives or the server closes it.

## Findings

- **Source**: flutter-reviewer (P1, confidence: 88)
- **Location**: `app/lib/features/chat/services/background_stream_manager.dart:88-97` (`_evictIfNeeded`) and lines 100-134 (`_consumeStream`)
- **Evidence**: `_ActiveStream.cancel()` only closes `controller`. The source stream from `_service.streamChat()` has no explicit cancellation mechanism. `_consumeStream` uses `await for` which blocks on the next event.

## Proposed Solutions

### Solution A: Store and cancel source StreamSubscription (Recommended)
Store the source `StreamSubscription` in `_ActiveStream` and cancel it on eviction:
```dart
class _ActiveStream {
  StreamSubscription<StreamEvent>? sourceSubscription;
  // set in _consumeStream via stream.listen() instead of await for
  void cancel() {
    sourceSubscription?.cancel();
    if (!controller.isClosed) controller.close();
  }
}
```

- **Pros**: Immediately cancels HTTP connection; clean resource management
- **Cons**: Need to refactor `await for` to `.listen()`
- **Effort**: Medium
- **Risk**: Low (need to refactor await for to listen)

### Solution B: Convert `_consumeStream` to use `.listen()` with stored subscription
Convert `_consumeStream` from `await for` to `.listen()` with stored subscription for cancellation.

- **Pros**: Same as Solution A, just the implementation approach
- **Cons**: Same as Solution A
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/services/background_stream_manager.dart`

## Acceptance Criteria

- [ ] Evicted streams have their HTTP connections closed immediately
- [ ] No lingering HTTP connections after eviction
- [ ] Source subscription is properly tracked and cancelled on stream lifecycle events

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
