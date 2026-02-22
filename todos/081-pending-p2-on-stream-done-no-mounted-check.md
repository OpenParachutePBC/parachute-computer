---
status: pending
priority: p2
issue_id: 79
tags: [code-review, flutter, crash, streaming]
dependencies: []
---

# `_onSendStreamDone` missing `mounted` check

## Problem Statement
`_onSendStreamDone()` mutates state (`state = state.copyWith(...)`) and calls `invalidate()` without checking if the notifier is still mounted. If the user navigates away and the provider is disposed before the stream completes, this could throw.

## Findings
- **Source**: flutter-reviewer (P2, confidence: 83)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart` — `_onSendStreamDone` method
- **Evidence**: No `mounted` guard before `state = state.copyWith(...)`. Other terminal handlers in the same file do check mounted state.

## Proposed Solutions
### Solution A: Add mounted guard (Recommended)
- **Pros**: Prevents exceptions; matches pattern used elsewhere in codebase
- **Cons**: None
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`
- **Implementation note**: Add `if (!mounted) return;` at the top of `_onSendStreamDone`

## Acceptance Criteria
- [ ] No exceptions thrown when stream completes after provider disposal
- [ ] `_onSendStreamDone` checks `mounted` before state mutation

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|

## Resources
- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
