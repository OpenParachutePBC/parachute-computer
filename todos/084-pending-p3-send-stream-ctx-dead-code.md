---
status: pending
priority: p3
issue_id: 79
tags: [code-review, flutter, dead-code]
dependencies: []
---

# `_sendStreamCtx` instance field is dead code

## Problem Statement
The `_sendStreamCtx` field on `ChatMessagesNotifier` is written 11 times but never read. It was apparently intended for external access to the stream context, but all usages pass the context object via closure to callbacks. The field is pure dead code.

## Findings
- **Source**: code-simplicity-reviewer (P3, confidence: 95)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart:273`
- **Evidence**: `_sendStreamCtx = ctx;` and `_sendStreamCtx = null;` appear throughout, but no code reads `_sendStreamCtx`.

## Proposed Solutions
### Solution A: Remove the `_sendStreamCtx` field entirely (Recommended)
- **Pros**: Eliminates dead code, reduces memory footprint, improves code clarity
- **Cons**: None
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria
- [ ] `_sendStreamCtx` field removed
- [ ] All assignments removed
- [ ] No compilation errors

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|

## Resources
- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
