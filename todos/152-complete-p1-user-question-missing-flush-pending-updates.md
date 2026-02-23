---
status: complete
priority: p1
issue_id: 109
tags: [code-review, flutter, bug, streaming, chat]
dependencies: []
---

# `userQuestion` stream event handler missing `_flushPendingUpdates()` call

## Problem Statement

The `userQuestion` case in `_handleSendStreamEvent` calls `_performMessageUpdate` directly (bypassing the throttle), but does NOT call `_flushPendingUpdates()` first. The `toolUse` case (the closest analogous handler) explicitly calls `_flushPendingUpdates()` before its `_performMessageUpdate` call. If a throttled text update is buffered in `_pendingContent` when the `userQuestion` event arrives, the buffered text state could be overwritten or rendered in the wrong order — the throttle timer will later flush `_pendingContent`, which is an alias to the same `ctx.accumulatedContent` list that was just mutated by the `userQuestion` handler.

## Findings

- **Sources**: performance-oracle (P2, confidence: 88), architecture-strategist (P1, confidence: 88)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart:1663` — `case StreamEventType.userQuestion:`
- **Evidence**:
  ```dart
  // toolUse case — line 1468 — correctly calls _flushPendingUpdates() first
  case StreamEventType.toolUse:
    _flushPendingUpdates();   // ← present
    ...
    _performMessageUpdate(ctx.accumulatedContent, isStreaming: true);

  // userQuestion case — missing the flush
  case StreamEventType.userQuestion:
    // No _flushPendingUpdates() call
    ...
    _performMessageUpdate(contentList, isStreaming: true);
  ```

## Proposed Solutions

### Solution A: Add `_flushPendingUpdates()` at top of `userQuestion` case (Recommended)
```dart
case StreamEventType.userQuestion:
  _flushPendingUpdates();  // flush any buffered text before transforming the tool entry
  debugPrint('[ChatMessagesNotifier] Received user_question event: ${event.questionRequestId}');
  {
    // ... existing mutation code
    _performMessageUpdate(contentList, isStreaming: true);
  }
  state = state.copyWith(pendingUserQuestion: { ... });
  break;
```
- **Pros**: Exactly mirrors the `toolUse` pattern; prevents lost buffered text content; 1-line change
- **Cons**: None
- **Effort**: Trivial
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria

- [ ] When a `userQuestion` event arrives while text is buffered in the throttle, the buffered text appears in the correct position before the inline question card
- [ ] Pattern matches `toolUse` case: `_flushPendingUpdates()` called before `_performMessageUpdate`

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
- toolUse handler: `chat_message_providers.dart:1468`
