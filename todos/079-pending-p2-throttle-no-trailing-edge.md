---
status: pending
priority: p2
issue_id: 79
tags: [code-review, flutter, performance, streaming]
dependencies: []
---

# Streaming throttle has no trailing-edge flush

## Problem Statement
The 50ms `Throttle` used for text content updates is leading-edge only. When a burst of text events is followed by a `toolUse` event, the last ~250ms of accumulated text isn't flushed before the tool call renders. The user sees a visual stutter — text appears to freeze briefly, then jumps forward when the tool use arrives and triggers `_flushPendingUpdates()`.

## Findings
- **Source**: performance-oracle (P2, confidence: 95)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart` — throttle usage in `_handleSendStreamEvent` and `_handleStreamEvent`
- **Evidence**: `Throttle(duration: Duration(milliseconds: 50))` is leading-edge. No trailing flush mechanism exists outside of the explicit `_flushPendingUpdates()` call before tool use events.

## Proposed Solutions
### Solution A: Add trailing-edge support (Recommended)
- **Pros**: Ensures last text update is always flushed; no visual stutter
- **Cons**: Requires modifying the `Throttle` class or adding parallel debounce timer
- **Effort**: Small
- **Risk**: Low

### Solution B: Flush on all terminal events
- **Pros**: Simple, explicit control
- **Cons**: May cause extra UI updates
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria
- [ ] No visible text stutter before tool call rendering
- [ ] Final text update displayed within 50ms of last text event

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|

## Resources
- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
