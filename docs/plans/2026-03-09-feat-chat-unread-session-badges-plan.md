---
title: Chat unread session badges
type: feat
date: 2026-03-09
issue: 215
---

# Chat Unread Session Badges

Per-session unread dots in the Chat tab. When a chat completes while you're not viewing it, a small colored dot appears on that session's list item. Tapping into the session clears the dot. The Chat tab badge stays in sync — derived from the count of unread sessions.

## Acceptance Criteria

- [x] Small colored dot appears on session list items that completed while not being viewed
- [x] Dot clears when tapping into that specific session
- [x] Chat tab badge count equals `unreadSessionIds.length + pendingPairingCount` (no more bulk clear on tab switch)
- [x] Completing a session while viewing it produces no dot (existing behavior preserved)
- [x] Completing a session while on another tab or backgrounded adds the session to the unread set
- [x] Toast behavior unchanged — still fires for completions on chat tab but different session

## Context

### Files to modify

| File | Change |
|------|--------|
| `app/lib/features/chat/providers/agent_completion_provider.dart` | `unreadCount: int` → `unreadSessionIds: Set<String>`, `clearUnread()` → `markRead(sessionId)` |
| `app/lib/features/chat/widgets/session_list_item.dart` | Add `isUnread` param, render dot next to type icon |
| `app/lib/features/chat/widgets/date_grouped_session_list.dart` | Accept `Set<String> unreadSessionIds`, pass `isUnread` to each `SessionListItem` |
| `app/lib/features/chat/screens/chat_hub_screen.dart` | Watch `agentCompletionProvider`, pass `unreadSessionIds` to `DateGroupedSessionList` |
| `app/lib/features/chat/providers/chat_session_actions.dart` | Call `markRead(sessionId)` inside `switchSessionProvider` |
| `app/lib/main.dart` | Update `_buildChatTabIcon` to use `.unreadSessionIds.length`, remove `clearUnread()` call from `onDestinationSelected` |

### Patterns to follow

- Existing `_badge()` and `_buildTrustBadge()` in `SessionListItem` for visual reference (though the dot is simpler — no text, just a circle)
- `SessionListItem` stays a `StatelessWidget` — unread state passed as param, not watched via ConsumerWidget
- Prop-drill the `Set<String>` from `ChatHubScreen` → `DateGroupedSessionList` → `SessionListItem` to avoid coupling widgets to the provider

### Key detail: markRead in switchSessionProvider

Calling `markRead` inside `switchSessionProvider` (not just `_openSession`) ensures the badge clears for all entry paths: hub tap, deep links, pending chat prompts, send-to-chat events. One call site covers everything.

### Dot visual

Small 8px circle, positioned to the left of or overlapping the type icon (similar to iOS Mail unread indicator). Use `BrandColors.turquoise` / `BrandColors.nightTurquoise` for the dot color to match the app's accent.
