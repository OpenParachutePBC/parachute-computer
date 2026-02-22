---
status: pending
priority: p1
issue_id: 79
tags: [code-review, flutter, bug, streaming]
dependencies: []
---

# `_onSendStreamError` can double-report errors

## Problem Statement

When a `StreamEventType.error` or `StreamEventType.typedError` terminal event is received, `_handleSendStreamEvent` handles it by setting error state and breaking. But the `BackgroundStreamManager._consumeStream` also breaks on terminal events and may trigger the `onError` callback or close the controller with an error, causing `_onSendStreamError` to fire as well. This results in the error being reported twice — once from the event handler and once from the subscription error callback.

## Findings

- **Source**: flutter-reviewer (P1, confidence: 90)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart` — `_handleSendStreamEvent` (error/typedError cases) and `_onSendStreamError`
- **Evidence**: Terminal events (error, typedError) are handled in the switch statement AND also detected by `_consumeStream` which breaks the loop. If the stream errors after the terminal event, `onError` fires too.

## Proposed Solutions

### Solution A: Add error handling guard flag (Recommended)
Add a guard flag in `_SendStreamContext` like `bool errorHandled = false`. Set it in `_handleSendStreamEvent` when error/typedError is processed. Check it in `_onSendStreamError` and skip if already handled.

- **Pros**: Simple, minimal code change; prevents duplicate error reporting
- **Cons**: Adds state flag to context
- **Effort**: Small
- **Risk**: None

### Solution B: Handle only unexpected errors in `_onSendStreamError`
Have `_onSendStreamError` only handle unexpected errors (not errors already signaled via stream events).

- **Pros**: Cleaner separation of concerns
- **Cons**: Requires distinguishing between expected and unexpected errors
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria

- [ ] Error events are reported to the user exactly once
- [ ] Both error paths (stream event and subscription error) are covered
- [ ] No duplicate error snackbars or error state changes

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
