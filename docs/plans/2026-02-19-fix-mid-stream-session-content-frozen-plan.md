---
title: "fix: Mid-stream session content frozen on return"
type: fix
date: 2026-02-19
issue: 72
---

# fix: Mid-stream session content frozen on return

## Overview

When a user navigates back to a session that's actively streaming, the UI shows the stop button (correctly detecting the active stream) but content appears frozen. The user must manually refresh to see progress. This is a P1 bug affecting the core chat UX — it breaks every multi-session workflow.

**Root cause:** `BackgroundStreamManager.registerStream()` is never called — it's dead code. The `sendMessage()` method consumes the SSE stream inline via `await for` and handles background mode by skipping UI updates. When the user returns, `loadSession()` tries to reattach via `BackgroundStreamManager` but finds nothing registered, so it falls back to 2-second polling against the server transcript API.

## Problem Statement

The app has two stream consumption paths, but only one is wired up:

| Path | Mechanism | When Used | Real-Time? |
|------|-----------|-----------|------------|
| **Inline `await for`** | `sendMessage()` consumes SSE directly, skips UI updates when `isBackgroundStream == true` | Always (current) | Only for active session |
| **BackgroundStreamManager** | `registerStream()` → broadcast controller → `reattachCallback()` | Never (dead code) | Yes, via reattach |

The `await for` loop in `sendMessage()` (line 1262 of `chat_message_providers.dart`) keeps the HTTP connection alive in the background, so the server continues processing. But it provides no mechanism for the UI to reattach and receive events in real-time when the user returns. The only option is the polling fallback, which:

- Polls every 2 seconds (perceived as frozen)
- Reloads the full transcript each time (inefficient)
- Times out after 60 seconds (gives up on long tasks)
- Has no incremental update mechanism

## Proposed Solution

**Refactor `sendMessage()` to register its stream with `BackgroundStreamManager`** so the existing reattach mechanism works.

The approach: instead of `await for` inline in `sendMessage()`, pass the `_service.streamChat()` stream to `_streamManager.registerStream()`. The manager's `_consumeStream()` keeps the HTTP connection alive in the background. The subscription returned by `registerStream()` delivers events to the UI. On session switch, cancel the subscription (not the stream). On return, reattach via `reattachCallback()`.

This is **Option A from the issue brainstorm** — eliminate polling mode for the common case.

### What Changes

1. **`sendMessage()` uses `registerStream()` instead of `await for`** — The stream is registered with `BackgroundStreamManager`, which consumes it via its own `await for` in `_consumeStream()`. The UI receives events through the broadcast controller subscription.

2. **Stream event handling moves to callbacks** — The current 500+ line `switch` block inside `sendMessage()` becomes a callback passed to `registerStream()`. When the session is in foreground, events update the UI. When backgrounded, the manager still consumes events (keeping the HTTP connection alive) but no UI callbacks fire.

3. **`prepareForSessionSwitch()` cancels the UI subscription, not the stream** — Currently `_resetTransientState()` has nothing meaningful to cancel (the `await for` can't be cancelled). After this fix, it cancels `_currentStreamSubscription` which detaches from the broadcast controller without stopping the background consumption.

4. **`loadSession()` reattach path works** — The existing code at line 467 (`if (_streamManager.hasActiveStream(sessionId))`) now finds the registered stream and reattaches for real-time updates.

5. **Polling kept as fallback for app restart only** — When the server reports an active stream but `BackgroundStreamManager` has nothing (app was killed and restarted), polling remains as the fallback.

### What Doesn't Change

- **Server-side**: No changes to `orchestrator.py` or `chat.py`. Active stream tracking is already correct.
- **`BackgroundStreamManager` API**: The `registerStream()`, `reattachCallback()`, `cancelStream()` API is already well-designed. Minor additions for stream limits only.
- **Chat screen rendering**: Stop button, message list, and streaming indicators work as-is once state updates flow correctly.

## Technical Approach

### Phase 1: Wire `sendMessage()` Through BackgroundStreamManager

**File: `app/lib/features/chat/providers/chat_message_providers.dart`**

**Step 1: Extract event handler from `sendMessage()`**

The current `await for` loop body (lines 1278-1644) contains a massive `switch` on `event.type`. Extract this into a method like `_handleSendStreamEvent(StreamEvent event, String displaySessionId, ...)` that encapsulates all the event handling logic (session event, text accumulation, tool calls, terminal events, etc.).

This method should:
- Accept the event and the session context (display session ID, accumulated content list, etc.)
- Return normally for non-terminal events
- Handle terminal events (done, error, aborted) by finalizing state

**Step 2: Register stream with BackgroundStreamManager**

Replace:
```dart
await for (final event in _service.streamChat(...)) {
  // 400 lines of event handling
}
```

With:
```dart
final stream = _service.streamChat(...);
_currentStreamSubscription = _streamManager.registerStream(
  sessionId: displaySessionId,
  stream: stream,
  onEvent: (event) => _handleSendStreamEvent(event, displaySessionId, ...),
  onDone: () => _onStreamDone(displaySessionId),
  onError: (error) => _onStreamError(error, displaySessionId),
);
_activeStreamSessionId = displaySessionId;
```

**Step 3: Handle "background stream" detection differently**

Currently, the `isBackgroundStream` check (line 1281) uses `_activeStreamSessionId != displaySessionId` to skip UI updates. After the refactor:
- When the user switches sessions, `_resetTransientState()` cancels `_currentStreamSubscription`
- This detaches from the broadcast controller — events stop reaching the callback
- The `BackgroundStreamManager._consumeStream()` continues consuming the HTTP stream
- No explicit "background mode" check needed — the subscription cancel handles it

**Step 4: Handle the `Completer` pattern for `sendMessage()` return**

`sendMessage()` is currently `async` and naturally awaits the `await for` loop. After refactoring to `registerStream()` (which is synchronous and returns immediately), `sendMessage()` needs to await stream completion differently.

Options:
- Use a `Completer<void>` that completes in the `onDone`/`onError` callbacks
- Or let `sendMessage()` return immediately after registration (it doesn't need to block)

**Recommendation**: Let `sendMessage()` return after registration. The terminal event callbacks handle cleanup. This matches how the UI works — `sendMessage()` doesn't need to block the caller.

### Phase 2: Add Stream Limit to BackgroundStreamManager

**File: `app/lib/features/chat/services/background_stream_manager.dart`**

Add a max concurrent streams limit to prevent resource exhaustion:

```dart
static const int maxConcurrentStreams = 5;
```

In `registerStream()`, before registering a new stream:
1. Check `_activeStreams.length >= maxConcurrentStreams`
2. If over limit, find the oldest stream (by insertion order — Dart `Map` preserves order)
3. Cancel the oldest stream via `cancelStream(oldestSessionId)`
4. Log: `"[BackgroundStreamManager] Evicting oldest stream: $oldestSessionId (limit: $maxConcurrentStreams)"`

When a stream is evicted:
- The broadcast controller closes, notifying any active subscribers
- The source `await for` in `_consumeStream()` continues to completion (the controller close doesn't break the source loop — need to fix this)
- **Fix needed**: `_consumeStream()` should check `controller.isClosed` in its loop and break if the controller was closed externally (eviction). This prevents a leaked HTTP connection.

### Phase 3: Add Throttling to Reattach Path

**File: `app/lib/features/chat/providers/chat_message_providers.dart`**

The reattach event handler (`_handleStreamEvent` at line 660) calls `_updateOrAddAssistantMessage()` directly — bypassing the 50ms `_streamingThrottle` used in the primary `sendMessage()` path. During rapid SSE events (20+ per second), this causes excessive widget rebuilds.

Fix: Apply the same throttle in `_handleStreamEvent` for text-content updates, or (better) after the refactor, both paths use the same extracted event handler which already includes throttling.

### Phase 4: Verify Polling Fallback (App Restart Case)

The polling fallback at `_startPollingForStreamCompletion()` (line 579) remains as-is for the app restart case:
- Server reports active stream
- `BackgroundStreamManager` has nothing (fresh after app restart)
- Falls through to polling

No changes needed here — the lifecycle fixes from PR #58 already addressed timer leaks, max timeout (30 ticks / 60s), and disposal guards.

## Acceptance Criteria

### Functional Requirements

- [ ] User navigates to mid-stream session → content updates in real-time (no 2s polling delay)
- [ ] Stop button shows AND content streams simultaneously
- [ ] Works across session switches: A → B → A with A still streaming
- [ ] Works for rapid switching: A → B → A → B → A
- [ ] Stream completes in background → user returns → sees complete response
- [ ] Multiple concurrent background streams work (up to limit)
- [ ] Stream limit enforced: 6th concurrent stream evicts oldest
- [ ] Evicted stream's session loads correctly from transcript on next visit
- [ ] App restart with active server stream → polling fallback works (existing behavior preserved)
- [ ] Abort (stop button) works during reattached stream

### Non-Functional Requirements

- [ ] No memory leaks from background streams (verify with DevTools)
- [ ] HTTP connections properly closed when streams complete or are evicted
- [ ] No excessive widget rebuilds during reattach (throttle applied)
- [ ] Polling fallback still caps at 60 seconds

## Files to Modify

**Primary changes:**
- `app/lib/features/chat/providers/chat_message_providers.dart` — Refactor `sendMessage()` to use `registerStream()`, extract event handler, update `_reattachToBackgroundStream()` and reattach event handling
- `app/lib/features/chat/services/background_stream_manager.dart` — Add stream limit, fix `_consumeStream()` to break on controller close (eviction)

**Verify/minor:**
- `app/lib/features/chat/screens/chat_screen.dart` — Verify streaming state renders correctly (likely no changes needed)

**No server changes needed.**

## Risk Analysis

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `sendMessage()` refactor breaks event handling | Medium | High | Extract event handler first as a pure refactor (no behavior change), then wire through manager |
| Background stream keeps HTTP connection after eviction | Medium | Medium | Check `controller.isClosed` in `_consumeStream()` loop |
| Race condition: session switch during stream registration | Low | Medium | Dart is single-threaded; session guard in event handler already exists |
| `Completer` pattern adds complexity to `sendMessage()` | Low | Low | Let `sendMessage()` return immediately after registration instead |

## Open Questions Resolved

From the issue brainstorm:

1. **Stream limit**: 5 concurrent, hardcoded. Close oldest by insertion order.
2. **Polling fallback**: Kept for app restart case only. Unchanged from current implementation.
3. **Events during session switch**: No buffering needed. Transcript loaded by `loadSession()` provides history; reattach picks up from that point. Brief gap is acceptable.
4. **Visual indicator for reconnecting**: Not in scope. Reattach is instant (no reconnection delay). The stop button already signals active streaming.

## References

- Issue #72: [Mid-stream session shows stop button but content doesn't update](https://github.com/OpenParachutePBC/parachute-computer/issues/72)
- PR #58: Stream lifecycle cleanup (timer leaks, stale state, disposal races) — already merged
- PR #57: Mid-stream message injection — already merged
- Related: Issue #70 (AskUserQuestion lost on session switch) — separate fix, similar root cause
- `app/lib/features/chat/services/background_stream_manager.dart` — Dead code that becomes the solution
- `app/lib/features/chat/providers/chat_message_providers.dart:1262` — Current `await for` loop to refactor
