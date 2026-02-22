---
status: pending
priority: p2
issue_id: 79
tags: [code-review, flutter, regression, streaming]
dependencies: []
---

# `sessionUnavailable` and `aborted` handlers no longer stop event consumption

## Problem Statement
In the old `await for` loop, `sessionUnavailable` and `aborted` handlers used `return` to exit the loop entirely. In the refactored callback-based approach, the handlers use `break` in a switch statement but the subscription stays active — events continue to arrive and be processed until `BackgroundStreamManager._consumeStream` detects the terminal event. This means extra events after sessionUnavailable or aborted may trigger state mutations.

## Findings
- **Source**: flutter-reviewer (P2, confidence: 85 for sessionUnavailable, 83 for aborted)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart` — `_handleSendStreamEvent` switch cases for `sessionUnavailable` and `aborted`
- **Evidence**: The old code used `return` to exit the entire `await for` loop. The new code is a callback — it can't "return from the loop." The subscription continues until the stream manager breaks on the terminal event.

## Proposed Solutions
### Solution A: Cancel subscription in terminal handlers (Recommended)
- **Pros**: Immediately stops processing; matches old behavior semantically
- **Cons**: Requires tracking the subscription reference
- **Effort**: Small
- **Risk**: Low

### Solution B: Add flag to prevent further processing
- **Pros**: No subscription cancellation needed
- **Cons**: Still processes events internally; less clean
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`
- **Implementation note**: Cancel `_currentStreamSubscription` in terminal event handlers:
```dart
case StreamEventType.sessionUnavailable:
  // handle state...
  _currentStreamSubscription?.cancel();
  break;
```

## Acceptance Criteria
- [ ] No events processed after sessionUnavailable or aborted
- [ ] State mutations stop immediately on terminal events

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|

## Resources
- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
