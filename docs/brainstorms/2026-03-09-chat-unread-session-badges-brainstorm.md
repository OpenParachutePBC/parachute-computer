# Chat Unread Session Badges

**Status**: Brainstorm
**Priority**: P2
**Labels**: app, chat
**Issue:** #215

---

## What We're Building

Per-session unread indicators in the Chat tab. When a chat's agent completes (`done` event) while you're not viewing that session, a small colored dot appears on that session's list item. Tapping into the session clears the dot. The global Chat tab badge stays in sync — its count equals the number of sessions with unread dots.

## Why This Approach

The existing `AgentCompletionNotifier` already handles completion events and drives the tab badge. The minimal change is evolving it from a global `int unreadCount` to a `Set<String> unreadSessionIds`. Everything else derives from that:

- **Tab badge count** = `unreadSessionIds.length` (+ pending pairing count)
- **Per-session dot** = `unreadSessionIds.contains(sessionId)`
- **Clear on tap** = `markRead(sessionId)` removes from the set
- **No new providers needed** — completions already flow through this notifier

A separate `UnreadSessionsProvider` was considered but adds indirection for no benefit.

## Key Decisions

- **Visual treatment**: Small colored dot (like iOS mail unread), not a text badge. Text badges are used for status labels (Pending, Setup, Archived). A dot is more natural for transient "unread" state.
- **Clearing behavior**: Badge clears when you tap into the specific session, not when you arrive at the Chat tab or scroll past it.
- **Tab badge in sync**: The global Chat tab badge no longer clears all at once on tab switch. It derives from the per-session unread set, reaching zero only when every unread session has been tapped into.
- **In-memory only**: `Set<String>` lives in the Riverpod notifier. No DB persistence for now. The shape (`Set<String>` of session IDs) maps cleanly to a `last_read_at` column later if we ever want persistence across restarts.
- **State change**: `AgentCompletionState.unreadCount: int` becomes `AgentCompletionState.unreadSessionIds: Set<String>`. The `clearUnread()` method becomes `markRead(String sessionId)`. Tab badge derivation changes accordingly in `main.dart`.

## Open Questions

- **Dot color/placement**: Exact color and position on the session list item — decide during implementation.
- **DB persistence**: Future consideration. Could add `last_read_at` per session and compare against `updatedAt`. Not needed now.
