---
status: pending
priority: p3
issue_id: 79
tags: [code-review, flutter, dead-code]
dependencies: []
---

# `_ActiveStream.onEvent` field is dead code

## Problem Statement
`_ActiveStream.onEvent` stores the callback passed during registration but is never read anywhere. Events are dispatched via the broadcast `StreamController`, not through this stored callback.

## Findings
- **Source**: code-simplicity-reviewer (P3, confidence: 92), architecture-strategist (P3, confidence: 92), pattern-recognition-specialist (P3, confidence: 88)
- **Location**: `app/lib/features/chat/services/background_stream_manager.dart:201`
- **Evidence**: `required this.onEvent` in constructor, but no code accesses `activeStream.onEvent` after construction.

## Proposed Solutions
### Solution A: Remove the `onEvent` field from `_ActiveStream` (Recommended)
- **Pros**: Eliminates dead code, simplifies data structure
- **Cons**: None
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/services/background_stream_manager.dart`

## Acceptance Criteria
- [ ] `onEvent` field removed from `_ActiveStream`
- [ ] Constructor updated
- [ ] No compilation errors

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|

## Resources
- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
