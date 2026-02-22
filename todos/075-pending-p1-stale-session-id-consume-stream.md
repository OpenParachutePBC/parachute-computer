---
status: pending
priority: p1
issue_id: 79
tags: [code-review, flutter, bug, streaming]
dependencies: []
---

# Stale sessionId in `_consumeStream` finally block

## Problem Statement

`_consumeStream()` in `background_stream_manager.dart` captures `sessionId` as a parameter. When `updateSessionId(oldId, newId)` remaps the key in `_activeStreams`, the `finally` block at line 130 still uses the original captured `sessionId`, so `_activeStreams.remove(sessionId)` removes nothing (the old key was already removed by `updateSessionId`). The entry under the new ID is never cleaned up, causing a leaked map entry that makes `hasActiveStream()` return true forever for that session.

## Findings

- **Source**: flutter-reviewer (P1, confidence: 95), security-sentinel (P3, confidence: 82), architecture-strategist (P2, confidence: 92)
- **Location**: `app/lib/features/chat/services/background_stream_manager.dart:100-134` (the `_consumeStream` method, specifically the `finally` block at line 130)
- **Evidence**: `_consumeStream` takes `String sessionId` as parameter (line 101). `updateSessionId` at line 142-149 removes old key and inserts new key. But `_consumeStream`'s finally block at line 130 does `_activeStreams.remove(sessionId)` using the stale captured parameter, not the potentially-updated `_ActiveStream.sessionId`.

## Proposed Solutions

### Solution A: Use `_ActiveStream.sessionId` (Recommended)
Use `_ActiveStream.sessionId` instead of the captured parameter in the finally block:
```dart
} finally {
  final activeStream = _activeStreams.values.where((s) => s.sessionId == sessionId || s.controller == controller).firstOrNull;
  final currentId = activeStream?.sessionId ?? sessionId;
  debugPrint('[BackgroundStreamManager] Stream completed for session: $currentId');
  _activeStreams.remove(currentId);
  ...
}
```
Or simpler: since `_ActiveStream.sessionId` is mutable, look up by controller identity or just use the `_ActiveStream` reference directly.

- **Pros**: Handles the mutable sessionId case correctly; ensures cleanup always uses current ID
- **Cons**: Slightly more complex lookup logic
- **Effort**: Small
- **Risk**: None

### Solution B: Close over the `_ActiveStream` object
Simplest fix — close over the `_ActiveStream` object itself, not just the sessionId, and remove using its current `.sessionId`:
```dart
Future<void> _consumeStream(
  _ActiveStream activeStreamRef,
  Stream<StreamEvent> source,
  StreamController<StreamEvent> controller,
) async {
  // ...
  } finally {
    _activeStreams.remove(activeStreamRef.sessionId);
    // ...
  }
}
```

- **Pros**: Cleanest refactor, eliminates parameter duplication
- **Cons**: Requires passing object reference instead of string
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/services/background_stream_manager.dart`

## Acceptance Criteria

- [ ] After `updateSessionId(old, new)`, when the stream completes, `_activeStreams` no longer contains an entry for the new ID
- [ ] `hasActiveStream(newId)` returns false after stream completion
- [ ] No leaked map entries for remapped sessions

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
