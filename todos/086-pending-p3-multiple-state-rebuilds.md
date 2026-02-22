---
status: pending
priority: p3
issue_id: 79
tags: [code-review, flutter, performance]
dependencies: []
---

# Multiple consecutive `state = state.copyWith()` calls cause excess rebuilds

## Problem Statement
In `_handleSendStreamEvent`, the `sessionEvent` case makes up to 4 consecutive `state = state.copyWith(...)` assignments: currentSessionId, activeStreamSessionId, messages, and isStreaming. Each triggers a Riverpod listener notification and widget rebuild. These could be batched into a single assignment.

## Findings
- **Source**: performance-oracle (P3, confidence: 92), flutter-reviewer (P3, confidence: 88)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart` — `_handleSendStreamEvent` sessionEvent case
- **Evidence**: Multiple sequential `state = state.copyWith(...)` calls within a single event handler.

## Proposed Solutions
### Solution A: Batch state changes into a single assignment (Recommended)
- **Pros**: Reduces Riverpod listener notifications, decreases widget rebuilds, improves performance
- **Cons**: None
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria
- [ ] Session event handler uses a single state assignment
- [ ] Widget rebuild count reduced (verifiable with Flutter DevTools)

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|

## Resources
- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
