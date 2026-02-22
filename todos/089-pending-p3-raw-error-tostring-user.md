---
status: pending
priority: p3
issue_id: 79
tags: [code-review, flutter, security, pre-existing]
dependencies: []
---

# Raw error `toString()` displayed to user

## Problem Statement
Error messages are displayed to the user via `error.toString()` without sanitization. Stack traces, internal class names, or server details could leak to the UI. This is a pre-existing pattern, not introduced by this PR.

## Findings
- **Source**: security-sentinel (P3, confidence: 80)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart` — error handling in `_onSendStreamError`
- **Evidence**: `error.toString()` passed to state as user-facing error message.

## Proposed Solutions
### Solution A: Map known error types to user-friendly messages (Recommended)
- **Pros**: Prevents information leakage, improves user experience, maintains security posture
- **Cons**: Requires maintaining error type mappings
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria
- [ ] No raw error strings shown to users
- [ ] Full errors logged in debug mode
- [ ] Known error types mapped to user-friendly messages

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|

## Resources
- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
