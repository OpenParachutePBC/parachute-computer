---
status: pending
priority: p3
issue_id: 79
tags: [code-review, flutter, naming]
dependencies: []
---

# Naming asymmetry: `_handleStreamEvent` should be `_handleReattachStreamEvent`

## Problem Statement
`_handleStreamEvent` handles events for the reattach path, while `_handleSendStreamEvent` handles events for the send path. The naming doesn't make the reattach context clear, leading to confusion about which handler is for which path.

## Findings
- **Source**: pattern-recognition-specialist (P3, confidence: 85)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart`
- **Evidence**: `_handleStreamEvent` vs `_handleSendStreamEvent` — asymmetric naming pattern.

## Proposed Solutions
### Solution A: Rename `_handleStreamEvent` to `_handleReattachStreamEvent` (Recommended)
- **Pros**: Makes the code intent clear, improves readability, maintains consistent naming patterns
- **Cons**: None
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria
- [ ] Method renamed
- [ ] All call sites updated

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|

## Resources
- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
