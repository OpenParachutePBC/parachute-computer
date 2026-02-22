---
status: pending
priority: p2
issue_id: 79
tags: [code-review, flutter, architecture, api-contract]
dependencies: []
---

# `sendMessage()` return semantics silently changed

## Problem Statement
Before the refactor, `sendMessage()` was `async` and awaited the `await for` loop — callers could `await sendMessage()` to know when the response was complete. After the refactor, `sendMessage()` returns immediately after stream registration. Any caller relying on the completion semantics (e.g., bot connectors, tests) now gets premature completion.

## Findings
- **Source**: architecture-strategist (P2, confidence: 88)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart` — `sendMessage()` method
- **Evidence**: The method is still `async` but no longer awaits stream completion. The `Completer` pattern mentioned in the plan was chosen as "let sendMessage return immediately."

## Proposed Solutions
### Solution A: Document and audit callers (Recommended)
- **Pros**: Lightweight; identifies any actual breakage; minimal code changes
- **Cons**: Relies on documentation being read; doesn't prevent future misuse
- **Effort**: Small (audit) to Medium (if fixes needed)
- **Risk**: Low

### Solution B: Restore completion semantics with Completer
- **Pros**: Restores original behavior; no caller changes needed
- **Cons**: More code; adds async complexity
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`
- **Callers to audit**: Bot connectors, integration tests, any code awaiting `sendMessage()`
- **Implementation note** (if needed): Add a `Completer<void>` that completes in `_onSendStreamDone`/`_onSendStreamError` and await it at the end of `sendMessage()`

## Acceptance Criteria
- [ ] All callers of `sendMessage()` work correctly with the new semantics
- [ ] Changed behavior is documented in dartdoc
- [ ] No silent failures in bot connectors or tests due to semantics change

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|

## Resources
- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
