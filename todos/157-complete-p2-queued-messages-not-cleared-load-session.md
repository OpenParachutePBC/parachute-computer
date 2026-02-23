---
status: complete
priority: p2
issue_id: 109
tags: [code-review, flutter, bug, streaming, chat]
dependencies: []
---

# `_queuedMessages` not cleared in `loadSession` — queued messages can leak across sessions

## Problem Statement

`_queuedMessages` is cleared in `_resetTransientState()`, which is called by `prepareForSessionSwitch`, `clearSession`, and `dispose`. However, `loadSession` does not call `_resetTransientState()` — it cancels the subscription and sets `_activeStreamSessionId = null` directly. If `loadSession` is called while a stream is active and messages are queued (e.g., via the polling path at line 666), those queued messages survive into the next session load. When the `done` event fires for the original stream, the flush path sends the queued messages to whatever session is current.

## Findings

- **Source**: architecture-strategist (P2, confidence: 82)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart` — `loadSession` method (~line 364)
- **Evidence**: `_resetTransientState()` at line 311 clears `_queuedMessages.clear()`. `loadSession` does not call `_resetTransientState()` and has no equivalent clear.

## Proposed Solutions

### Solution A: Add `_queuedMessages.clear()` inside `loadSession` (Recommended)
At the point where the subscription is cancelled (around line 365), add:
```dart
_queuedMessages.clear();
_pendingResendMessage = null;
```
- **Pros**: Minimal change; consistent with intent of `_resetTransientState`; prevents cross-session bleed
- **Cons**: None
- **Effort**: Trivial (1–2 lines)
- **Risk**: None

### Solution B: Have `loadSession` call `_resetTransientState()`
```dart
void loadSession(String sessionId) {
  _resetTransientState();
  // ... existing code
}
```
- **Pros**: Complete reset; covers all transient fields
- **Cons**: `_resetTransientState` also clears `_pendingContent` and resets throttle — these may need to persist across a `loadSession` call in some paths
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria

- [ ] Messages queued during session A are not sent to session B after `loadSession(sessionB)` is called
- [ ] `_queuedMessages` is empty at the start of any new session

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
