---
status: pending
priority: p2
issue_id: 79
tags: [code-review, flutter, quality, duplication]
dependencies: []
---

# Duplicated content accumulation logic across handlers

## Problem Statement
`_handleStreamEvent` (reattach path) and `_handleSendStreamEvent` (primary path) contain ~60 identical lines of content accumulation logic for text, toolResult, thinking, and warning events. This duplication means fixes must be applied in two places and the two paths can drift out of sync.

## Findings
- **Source**: pattern-recognition-specialist (P2, confidence: 95)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart` — both `_handleStreamEvent` and `_handleSendStreamEvent`
- **Evidence**: Nearly identical switch cases for `StreamEventType.text`, `StreamEventType.toolResult`, `StreamEventType.thinking`, `StreamEventType.warning` in both methods. Only difference is the UI update dispatch method.

## Proposed Solutions
### Solution A: Extract helper method (Recommended)
- **Pros**: DRY principle; fixes apply to both paths automatically; easier to maintain
- **Cons**: Requires careful extraction to handle differences in dispatch
- **Effort**: Medium
- **Risk**: Low

### Solution B: Unify paths after refactor settles
- **Pros**: Single source of truth; cleaner long-term
- **Cons**: Deferred; requires waiting for refactor to stabilize
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`
- **Implementation approach**: Extract content accumulation into a helper that takes a content list and returns the updated list. Each handler calls the helper and then dispatches the UI update its own way.

## Acceptance Criteria
- [ ] Content accumulation logic exists in one place
- [ ] Both paths produce identical behavior
- [ ] No logic drift between primary and reattach paths

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|

## Resources
- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
