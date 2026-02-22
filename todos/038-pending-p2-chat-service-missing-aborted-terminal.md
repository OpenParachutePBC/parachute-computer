---
status: pending
priority: p2
issue_id: 67
tags: [code-review, flutter, terminal-events]
dependencies: []
---

# Missing `aborted` Terminal Event in ChatService.streamChat

## Problem Statement

`chat_service.dart` line 218 now correctly exits on `done`, `error`, and `typedError`, but still omits `aborted`. Both `BackgroundStreamManager` and the provider's background-stream filter treat `aborted` as terminal. This asymmetry means an `aborted` event won't terminate the SSE generator in `ChatService`, holding a connection slot open until the server closes.

## Findings

- **Source**: architecture-strategist (88), performance-oracle (82), flutter-reviewer (90), parachute-conventions-reviewer (92)
- **Location**: `app/lib/features/chat/services/chat_service.dart:218-221`
- **Evidence**: `BackgroundStreamManager` checks `done | error | typedError | aborted`. `ChatService` checks `done | error | typedError` only.

## Proposed Solutions

### Solution A: Add `aborted` to the terminal check (Recommended)
One-line fix: add `event.type == StreamEventType.aborted` to the condition.
- **Pros**: Consistency across all terminal checks
- **Cons**: None
- **Effort**: Small (1 line)
- **Risk**: None

### Solution B: Extract `isTerminal` getter on StreamEventType
Add `bool get isTerminal` to the enum so all three sites use one source of truth.
- **Pros**: Prevents future drift, single definition of "terminal"
- **Cons**: Slightly more code, enum extension method
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

**Affected files:**
- `app/lib/features/chat/services/chat_service.dart`
- Optionally: `app/lib/features/chat/models/stream_event.dart` (if adding `isTerminal`)

## Acceptance Criteria

- [ ] `aborted` events terminate the SSE generator in `ChatService.streamChat`
- [ ] All three terminal-event checks are consistent

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #67 review | Same class of bug as the typedError fix — incomplete application across sites |

## Resources

- PR: #67
- Issue: #49
