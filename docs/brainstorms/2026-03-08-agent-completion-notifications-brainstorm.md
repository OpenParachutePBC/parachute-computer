# Agent Completion Notifications

**Date:** 2026-03-08
**Status:** Brainstorm
**Priority:** P2
**Modules:** app, computer
**Issue:** #206

---

## Context

The common workflow on the Daylight tablet (Android): prompt agents in the Chat tab, switch to Daily for freeform journaling, sometimes leave the app entirely for Messenger or email. Without any notification signal, it's easy to lose context and forget an agent is waiting — breaking the flow between tending agents and reflective writing.

The infrastructure is already in place:
- Server emits a typed `DoneEvent` when an agent finishes (with session title, duration, response summary)
- Flutter `ChatMessagesState.isStreaming` already flips to `false` on completion
- `flutter_local_notifications` plugin is installed and configured with Android notification channels (used by Daily's recording notifications)
- Chat tab already has a `Badge` widget pattern for pending pairing count
- Session list items already render status badges (Pending, Setup, Archived)

What's missing is a notification layer that connects these signals to the user across three surfaces.

---

## What We're Building

Three notification surfaces for agent completion, in order of depth:

### 1. In-App Toast
A brief snackbar/toast when a `DoneEvent` arrives and the user isn't looking at that session. Shows the session title + "finished." Disappears after a few seconds.

**When it fires:** User is in the app (any tab, or a different chat session).

### 2. Chat Tab Badge
An unread count badge on the Chat tab icon. Increments when an agent finishes while the user is on another tab (Daily, Brain, Vault). Clears when the user navigates to the Chat tab or opens the completed session.

**When it fires:** User is on a non-Chat tab within the app.

### 3. Android OS Notification
A local push notification when the app is backgrounded or the screen is off. Tapping it opens the app (ideally navigating to the completed session). Uses the existing `flutter_local_notifications` setup.

**When it fires:** App is not in the foreground.

Each notification shows the **session title** and a simple status like "finished."

---

## Why This Approach

- **Incremental surfaces** — toast and badge are pure Flutter, no platform code. OS notification reuses existing plugin. Each layer is independently useful.
- **Already-wired signals** — `DoneEvent` is the trigger. No new server work needed. The client already processes this event and flips `isStreaming`.
- **YAGNI** — No notification center, no sound/haptic (yet), no custom notification UI. Just the minimum to solve "I forgot my agent finished."
- **Android-first** — Primary device is the Daylight tablet. macOS desktop notifications can come later if needed.

---

## Key Decisions

1. **Individual notifications per session** — not batched. Each agent completion gets its own toast/badge increment/OS notification with the session title.
2. **Toast over banner** — brief snackbar, not a persistent banner. Low-interruption.
3. **Badge clears on tab switch** — navigating to the Chat tab clears the unread count. Simple mental model.
4. **OS notifications only when backgrounded** — no duplicate notification when the user is already looking at the app.
5. **Tap-to-navigate** — tapping the OS notification should open the app and ideally navigate to the specific session that finished.
6. **No new server work** — the `DoneEvent` already carries everything needed. This is a client-side feature.

---

## Open Questions

- **Badge scope:** Should the badge count only "finished while you were away" sessions, or also sessions with unread responses in general? Starting with just completion events keeps it simple.
- **Notification grouping:** If 3 agents finish in quick succession while backgrounded, should they be 3 separate OS notifications or grouped? Android supports notification grouping — worth doing if it's easy, but not essential for v1.
- **macOS support:** `flutter_local_notifications` has macOS support but it's less tested. Defer to a follow-up if there's demand.
- **Session navigation on tap:** Deep linking from OS notification to a specific chat session may need some routing work. Could start with just "open the app to the Chat tab" as a simpler first pass.
