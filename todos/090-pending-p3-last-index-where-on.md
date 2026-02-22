---
status: pending
priority: p3
issue_id: 79
tags: [code-review, flutter, performance]
dependencies: []
---

# `lastIndexWhere` O(n) per text event on accumulated content

## Problem Statement
Every text event calls `accumulatedContent.lastIndexWhere(...)` to find the last text content item. As the content list grows, this becomes O(n) per event. For long responses with hundreds of content items, this adds up.

## Findings
- **Source**: performance-oracle (P3, confidence: 85)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart` — `_handleSendStreamEvent` text case
- **Evidence**: `lastIndexWhere` on a growing list, called on every text event.

## Proposed Solutions
### Solution A: Cache the index of the last text content item (Recommended)
- **Pros**: Reduces event handling from O(n) to O(1), improves performance for long responses
- **Cons**: Requires cache maintenance
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria
- [ ] Text event handling is O(1) for content lookup
- [ ] Cached index updated correctly when new items are added

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|

## Resources
- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
