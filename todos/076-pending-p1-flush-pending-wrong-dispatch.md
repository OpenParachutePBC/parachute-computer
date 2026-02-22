---
status: pending
priority: p1
issue_id: 79
tags: [code-review, flutter, bug, streaming]
dependencies: []
---

# `_flushPendingUpdates` dispatches through wrong method for reattach path

## Problem Statement

`_flushPendingUpdates()` in `chat_message_providers.dart` stores content from the reattach path's `_handleStreamEvent` into `_pendingContent`, then flushes via `_performMessageUpdate()`. But the reattach path expects `_updateOrAddAssistantMessage()` (which handles adding new messages when none exist yet). If the flush fires for a reattach scenario where no assistant message exists yet, the update silently fails or targets the wrong message.

## Findings

- **Source**: flutter-reviewer (P1, confidence: 92)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart` — `_flushPendingUpdates` method and `_handleStreamEvent` method
- **Evidence**: `_pendingContent` is populated by both `_handleSendStreamEvent` (primary path) and `_handleStreamEvent` (reattach path). But `_flushPendingUpdates` only dispatches via one update method. The reattach path has its own `_updateReattachAssistantMessage()` that should be used.

## Proposed Solutions

### Solution A: Make the flush dispatch method configurable (Recommended)
Store which update function to call alongside the pending content, or have two separate pending content buffers (one for each path).

- **Pros**: Decouples content buffering from dispatch method; handles both paths correctly
- **Cons**: More state to track
- **Effort**: Medium
- **Risk**: Low

### Solution B: Remove shared `_pendingContent` for the reattach path
Remove shared `_pendingContent` for the reattach path and have the reattach throttle manage its own content directly.

- **Pros**: Eliminates path mixing in the buffer
- **Cons**: Duplicate buffering logic for two paths
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria

- [ ] Reattach path content updates display correctly when flushed before tool use events
- [ ] No silent failures when reattaching to a stream with no prior assistant message
- [ ] Both primary and reattach paths dispatch through appropriate update methods

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #79: fix(chat): wire sendMessage through BackgroundStreamManager
- Issue #72: Mid-stream session shows stop button but content doesn't update
