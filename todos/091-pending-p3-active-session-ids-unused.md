---
status: pending
priority: p3
issue_id: 79
tags: [code-review, flutter, dead-code, pre-existing]
dependencies: []
---

# `activeSessionIds` getter unused (pre-existing)

## Problem Statement
The `activeSessionIds` getter on `BackgroundStreamManager` returns a set of all session IDs with active streams, but it's never called anywhere in the codebase. Pre-existing dead code.

## Findings
- **Source**: code-simplicity-reviewer (P3, confidence: 90)
- **Location**: `app/lib/features/chat/services/background_stream_manager.dart:39`
- **Evidence**: `Set<String> get activeSessionIds => _activeStreams.keys.toSet();` — no usages found.

## Proposed Solutions
### Solution A: Remove the getter if no future use is planned (Recommended)
- **Pros**: Eliminates dead code, simplifies API surface
- **Cons**: Can be re-added when needed
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/services/background_stream_manager.dart`

## Acceptance Criteria
- [ ] Getter removed
- [ ] No compilation errors

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|

## Resources
- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
