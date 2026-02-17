# Chat Stream Lifecycle Fixes

**Status**: Brainstorm complete, ready for planning
**Priority**: P2 (Reliability / resource correctness)
**Modules**: app

---

## What We're Building

Fix five lifecycle management gaps in the Flutter chat streaming system (`ChatMessagesNotifier` and `ChatScreen`) that can cause timer leaks, stale state across sessions, and unnecessary resource consumption.

These are not user-visible crashes but they degrade reliability over time: leaked timers waste battery and bandwidth, stale throttle state causes missed UI updates, and orphaned subscriptions risk subtle state corruption.

---

## Why This Approach

### Problem 1: Poll Timer Leak

**Location**: `chat_message_providers.dart` lines 542-591

`_startPollingForStreamCompletion()` creates a `Timer.periodic` that polls every 2 seconds. Two issues:

1. **No max timeout** -- if the server becomes unreachable, the timer polls forever. Every poll tick fires an HTTP request to `hasActiveStream` + `getSessionTranscript`, consuming battery and bandwidth indefinitely.
2. **Disposal race** -- if the notifier is disposed while a poll tick is mid-flight (awaiting the `hasActiveStream` future), the callback can still fire after disposal. The `state.sessionId` check on line 556 guards against session switches but not disposal.

`prepareForSessionSwitch` (line 277-278) does cancel the timer, which is good. But `loadSession` does not cancel before starting a new poll, so rapid session loads could theoretically stack timers (though unlikely in practice since `loadSession` calls `_startPollingForStreamCompletion` which cancels first on line 550).

**Impact**: Battery drain, wasted network requests on unreachable servers, potential state mutation after disposal.

### Problem 2: Streaming Throttle Not Reset on Session Switch

**Location**: `chat_message_providers.dart` line 238

The `_streamingThrottle` (50ms Throttle) is only reset when streaming ends (`_updateAssistantMessage` with `isStreaming: false`, line 1524). It is NOT reset in `prepareForSessionSwitch`, `loadSession`, or `clearSession`.

If a user switches sessions while streaming is active, the throttle's `_lastCall` timestamp persists. When the new session starts streaming, the first few `_updateAssistantMessage` calls may be throttled (suppressed) because less than 50ms has elapsed since the previous session's last update.

**Impact**: First ~50ms of streaming content in a new session could be silently dropped if the user switched sessions mid-stream. Low severity but easy to fix.

### Problem 3: ChatScreen Subscription Lifecycle

**Location**: `chat_screen.dart` lines 86-87, 117-153

`_setupChatMessagesListener()` is called from `initState` via `addPostFrameCallback`. It uses `ref.listenManual()` which returns a `ProviderSubscription`. The method does cancel any existing subscription before creating a new one (line 119), which is correct.

The risk is theoretical: if `_setupChatMessagesListener()` were ever called more than once (e.g., from a rebuild path or hot reload), duplicate listeners could accumulate. Currently the code only calls it once from `initState`, so this is a low-risk defensive concern. Adding an assertion or guard would make the intent explicit.

**Impact**: Low risk currently. Defensive fix to prevent future regressions.

### Problem 4: Reattach Stream Content Accumulation

**Location**: `chat_message_providers.dart` lines 593-594

`_reattachStreamContent` is a mutable `List<MessageContent>` that accumulates content during background stream reattachment. It is reset on `done` (line 703), `aborted` (line 712), and `error` (line 720/729) events. However, it is NOT reset when:

- Session switches occur (`prepareForSessionSwitch`, `loadSession`)
- A new reattachment starts (`_reattachToBackgroundStream`)

If the user switches away from a session mid-reattachment (before a terminal event arrives), the list retains stale content. The next reattachment to a different session would start with leftover content from the previous session appended.

The `_handleStreamEvent` method does check `state.sessionId != sessionId` at line 602, which prevents stale events from updating state. But `_reattachStreamContent` itself is not session-scoped, so content from session A could leak into session B's list if session B reattaches before session A's terminal event arrives.

**Impact**: Stale content from a previous session could briefly appear in a new session's streaming display during reattachment. Medium severity.

### Problem 5: sessionUnavailable State Persists Across Sessions

**Location**: `chat_screen.dart` lines 146-149

The `_showSessionRecoveryDialog` is triggered when `next.sessionUnavailable != null && previous?.sessionUnavailable == null`. The `sessionUnavailable` field on `ChatMessagesState` is cleared in `recoverSession` and `dismissSessionUnavailable`, but it is NOT cleared in:

- `prepareForSessionSwitch` (line 284 creates a new `ChatMessagesState()` which does clear it -- this is actually fine)
- `loadSession` (line 419 creates a new `ChatMessagesState()` which also clears it)

After re-reading the code, `prepareForSessionSwitch` and `loadSession` both create fresh `ChatMessagesState` instances, which have `sessionUnavailable: null` by default. So this field IS implicitly cleared on session switch. The original concern may have been overstated.

However, there is still a narrow window: if `sessionUnavailable` is set while the user is in the process of switching sessions (after `prepareForSessionSwitch` but before `loadSession` completes), the dialog could appear for a session the user is navigating away from.

**Impact**: Very low. The state reset on session switch is correct. The dialog timing edge case is unlikely but worth noting.

---

## Key Decisions

1. **Add max poll timeout** -- Cap polling at ~60 seconds (30 ticks at 2s intervals). After that, stop polling and show a "refresh" hint. This prevents indefinite resource drain if the server is unreachable.

2. **Reset throttle on session switch** -- Add `_streamingThrottle.reset()` to `prepareForSessionSwitch` and `clearSession`. Trivial fix, no downside.

3. **Reset reattach content on session switch** -- Clear `_reattachStreamContent` in `prepareForSessionSwitch` and at the start of `_reattachToBackgroundStream`. This prevents cross-session content leakage.

4. **Add disposal guard to poll timer** -- Check `mounted` / `!disposed` state in the poll callback before accessing `state`. Use a `_disposed` flag since `StateNotifier` doesn't expose one directly.

5. **Keep ChatScreen subscription as-is** -- The current code is correct (single call from initState, cancel-before-replace pattern). Consider adding a debug assertion but no functional change needed.

---

## Open Questions

- Should the poll max timeout be configurable, or is a hardcoded 60s sufficient?
- Should we add a visual indicator when polling times out (e.g., a "Session may have completed -- tap to refresh" banner)?
- Is there value in making `_reattachStreamContent` session-scoped (e.g., a `Map<String, List<MessageContent>>`) rather than just clearing it? Probably YAGNI.

---

## Scope

All changes are in two files:
- `app/lib/features/chat/providers/chat_message_providers.dart`
- `app/lib/features/chat/screens/chat_screen.dart`

No server changes needed. No API changes. No new dependencies. This is purely a Flutter-side lifecycle cleanup.

Estimated effort: Small (1-2 hours). All fixes are localized, low-risk, and independently testable.
