---
status: pending
priority: p3
issue_id: 79
tags: [code-review, flutter, duplication]
dependencies: []
---

# Duplicated throttle wrapper pattern

## Problem Statement
Both `_updateReattachAssistantMessage()` and the primary path's throttle wrapper follow the same pattern: store pending content, call update on throttle tick. This is a minor duplication that could be consolidated.

## Findings
- **Source**: pattern-recognition-specialist (P3, confidence: 90)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart`
- **Evidence**: Two separate throttle instances with similar wrapper logic.

## Proposed Solutions
### Solution A: Extract a generic "throttled message updater" (Recommended)
- **Pros**: Reduces duplication, improves maintainability, single source of truth
- **Cons**: Requires abstraction design
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria
- [ ] Single throttle wrapper pattern used by both paths
- [ ] No behavior changes
- [ ] Code duplication reduced

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|

## Resources
- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
