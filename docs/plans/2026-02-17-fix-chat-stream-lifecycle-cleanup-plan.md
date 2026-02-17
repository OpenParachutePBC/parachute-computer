---
title: "fix: Chat stream lifecycle cleanup"
type: fix
date: 2026-02-17
issue: "#48"
modules: app
files:
  - app/lib/features/chat/providers/chat_message_providers.dart
  - app/lib/features/chat/screens/chat_screen.dart
---

# fix: Chat stream lifecycle cleanup

Fix timer leaks, stale state across sessions, and resource cleanup gaps in the Flutter chat streaming system. All changes are in `ChatMessagesNotifier` and `ChatScreen` — no server or API changes.

Brainstorm: [#48](https://github.com/OpenParachutePBC/parachute-computer/issues/48) | Brainstorm doc: `docs/brainstorms/2026-02-16-chat-stream-lifecycle-fixes-brainstorm.md`

---

## Enhancement Summary

**Deepened on:** 2026-02-17
**Research agents used:** Timer disposal patterns, Flutter session state cleanup, flutter-reviewer, performance-oracle, code-simplicity-reviewer, parachute-conventions-reviewer, pattern-recognition-specialist, architecture-strategist

### Key Improvements from Research
1. **Use `mounted` instead of `_disposed` flag** — `StateNotifier.mounted` is available in Riverpod 2.6.1 and already used in `SyncNotifier` in this codebase
2. **Create `_resetTransientState()` helper** — eliminates the "forgot to reset field X" anti-pattern found across 3 cleanup paths
3. **Add overlapping-callback guard** — prevents concurrent poll HTTP requests when callbacks take >2s
4. **Guard after every `await`** — each suspension point in the timer callback needs a `mounted` check
5. **Add `loadSession` session-ID guard** — one-line fix for the async race condition (promoted from "out of scope")
6. **Drop Fix 5** — ChatScreen subscription is already correct, assertion adds noise

### Architectural Notes (Deferred)
- ChatMessagesNotifier is a 1739-line God Object with 7 mutable transient fields — consider extracting a `StreamingContext` class in a follow-up
- Family + autoDispose providers would eliminate the session-scoping problem entirely — future refactor opportunity

---

## Problems & Fixes

### Fix 1: Poll timer leak + disposal race (HIGH)

**File**: `chat_message_providers.dart` — `_startPollingForStreamCompletion()` (~line 545)

**Problem**: `Timer.periodic(2s)` polls forever if server is unreachable. Also, async callback can access `state` after notifier disposal.

**Changes**:

1. Use `mounted` (not a custom `_disposed` flag) — already available on `StateNotifier` and already used in `SyncNotifier` at `sync_provider.dart:393`
2. Add tick counter as a local variable captured by closure (not a class field — encapsulation, auto-reset on new timer)
3. Add max 30 ticks (60 seconds) with graceful timeout behavior
4. Add `mounted` guard as first check in timer callback
5. Add `mounted` guard **after each `await`** (there are two: `hasActiveStream` and `getSessionTranscript`)
6. Add `_isPolling` flag to prevent overlapping async callbacks (if HTTP takes >2s, next tick fires while previous is in-flight)

```dart
// chat_message_providers.dart — _startPollingForStreamCompletion()
bool _isPolling = false; // Prevents overlapping async callbacks

void _startPollingForStreamCompletion(String sessionId) {
  _pollTimer?.cancel();
  _isPolling = false;
  var tickCount = 0; // Local — captured by closure, auto-resets
  const maxTicks = 30; // 60 seconds at 2s intervals

  _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
    // Guard 1: Disposed
    if (!mounted) { timer.cancel(); return; }

    // Guard 2: Overlapping callback
    if (_isPolling) return;

    tickCount++;

    // Guard 3: Session changed
    if (state.sessionId != sessionId) {
      timer.cancel();
      _pollTimer = null;
      return;
    }

    // Guard 4: Max timeout
    if (tickCount >= maxTicks) {
      debugPrint('[ChatMessagesNotifier] Poll timeout after ${maxTicks * 2}s');
      timer.cancel();
      _pollTimer = null;
      if (mounted) {
        state = state.copyWith(isStreaming: false);
      }
      return;
    }

    _isPolling = true;
    try {
      final stillActive = await _service.hasActiveStream(sessionId);
      if (!mounted) return; // Guard after await #1
      // ... existing logic ...

      final transcript = await _service.getSessionTranscript(sessionId);
      if (!mounted) return; // Guard after await #2
      // ... existing state update logic ...
    } catch (e) {
      debugPrint('[ChatMessagesNotifier] Poll error: $e');
    } finally {
      _isPolling = false;
    }
  });
}
```

### Research Insights (Fix 1)

**Best Practices:**
- `StateNotifier.mounted` is the idiomatic check — available since `state_notifier` 0.7.0. Prefer over custom `_disposed` flag. Already used in `SyncNotifier` in this codebase.
- Guard after **every** `await`, not just at callback entry. Each `await` is a suspension point where disposal or session switch could occur.
- `Timer.periodic` with async callbacks can cause concurrent execution if callback takes longer than interval. The `_isPolling` guard prevents this.
- Tick counter as a local variable is correct — Dart closures capture by reference, so the closure always sees the current value. A class field would pollute the notifier's state unnecessarily.

**Performance Considerations:**
- Each poll tick makes 2 HTTP requests (`hasActiveStream` + `getSessionTranscript`). The transcript endpoint reads and parses the entire JSONL file from disk. Over 30 ticks, this is up to 30 full file reads.
- Consider exponential backoff (2s→10s capped, ~80% fewer requests) as a future optimization — not in scope for this fix.
- The `mounted` check is a single boolean — negligible performance impact at 0.5 Hz.

**Edge Cases:**
- If `hasActiveStream` throws (server unreachable), the catch block swallows it and polling continues to next tick. This is correct — transient errors should not stop polling.
- Error ticks count toward the 30-tick max. This is acceptable — 60s wall-clock is the safety limit regardless of success/failure.

---

### Fix 2: Centralized transient state reset (MEDIUM)

**File**: `chat_message_providers.dart` — new `_resetTransientState()` method

**Problem**: `prepareForSessionSwitch`, `clearSession`, and `dispose` each clean up a different subset of the 7 mutable transient fields. This is the root cause of all the missed-cleanup bugs.

| Field | `prepareForSessionSwitch` | `clearSession` | `dispose` |
|-------|---------------------------|-----------------|-----------|
| `_currentStreamSubscription` | YES | YES | YES |
| `_activeStreamSessionId` | YES | YES | No |
| `_pollTimer` | YES | **No** | YES |
| `_streamingThrottle` | **No** | **No** | **No** |
| `_reattachStreamContent` | **No** | **No** | **No** |
| `_pendingContent` | **No** | **No** | **No** |
| `_pendingResendMessage` | **No** | YES | **No** |
| `_isPolling` (new) | **No** | **No** | **No** |

**Changes**:

Create a single `_resetTransientState()` method that resets ALL mutable transient fields. Call from all 3 cleanup paths.

```dart
/// Reset all mutable transient state that should not persist across sessions.
/// Called from prepareForSessionSwitch, clearSession, and dispose.
void _resetTransientState() {
  _currentStreamSubscription?.cancel();
  _currentStreamSubscription = null;
  _activeStreamSessionId = null;
  _pollTimer?.cancel();
  _pollTimer = null;
  _isPolling = false;
  _streamingThrottle.reset();
  _reattachStreamContent.clear();
  _pendingContent = null;
  _pendingResendMessage = null;
}
```

Then simplify each cleanup method:

```dart
void prepareForSessionSwitch(String newSessionId) {
  _resetTransientState();
  final hasActiveStream = _streamManager.hasActiveStream(newSessionId);
  state = ChatMessagesState(
    sessionId: newSessionId,
    isLoading: true,
    isStreaming: hasActiveStream,
  );
}

void clearSession({bool preserveWorkingDirectory = false}) {
  _resetTransientState();
  state = ChatMessagesState(/* ... */);
}

@override
void dispose() {
  _resetTransientState();
  super.dispose();
}
```

Also add `_reattachStreamContent.clear();` at the start of `_reattachToBackgroundStream()` (defensive — the primary clear is in `_resetTransientState`, but this guards the entry point).

### Research Insights (Fix 2)

**Best Practices:**
- This follows the pattern already used in this codebase: `StreamingRecordingNotifier` in `streaming_transcription_provider.dart` has a `_stopDurationTimer()` helper called from both `stopRecording()` and `dispose()`.
- Single cleanup method prevents the "forgot to add new field to all N cleanup paths" drift.
- Use `.clear()` instead of `= []` for lists when the list will be repopulated soon (avoids allocation). Use `= []` in dispose where the list won't be reused.

**Edge Cases:**
- `_resetTransientState()` is safe to call multiple times (all operations are idempotent).
- Calling `_pollTimer?.cancel()` after the timer has already been canceled is a no-op.
- `_streamingThrottle.reset()` just sets `_lastCall = null` — always safe.

---

### Fix 3: `loadSession` session-ID guard (LOW — promoted from out-of-scope)

**File**: `chat_message_providers.dart` — `loadSession()` (~line 422)

**Problem**: `loadSession` is async. If the user rapidly switches sessions (A → B), `prepareForSessionSwitch(B)` fires, but `loadSession(A)` is still in-flight. When it completes, it writes session A's data to `state`, overwriting session B's state. No session-ID guard exists before the final `state =` assignment.

**Changes**:

Add a single guard before the final state assignment in `loadSession`:

```dart
// Before the final state = ChatMessagesState(...) at ~line 422:
if (state.sessionId != sessionId) {
  debugPrint('[ChatMessagesNotifier] loadSession skipped — session switched to ${state.sessionId}');
  return;
}
```

### Research Insights (Fix 3)

**Why promoted from "out of scope":**
- Architecture reviewer and SpecFlow analysis both identified this as a real race condition, not theoretical.
- The lifecycle fixes in Fix 1 + Fix 2 make session switching feel more reliable, which encourages faster switching, which makes this race more likely.
- It is a one-line guard with the same risk profile as the other fixes — no reason to defer.

---

## Implementation Order

1. **Add `_isPolling` field** — needed by Fix 1
2. **Create `_resetTransientState()`** — consolidates all cleanup (Fix 2)
3. **Update `prepareForSessionSwitch`, `clearSession`, `dispose`** to call `_resetTransientState()` (Fix 2)
4. **Add poll timer guards** — max timeout + `mounted` checks + `_isPolling` guard (Fix 1)
5. **Add `loadSession` session-ID guard** (Fix 3)
6. **Add `_reattachStreamContent.clear()` at start of `_reattachToBackgroundStream()`** (defensive, Fix 2)

All changes are in `chat_message_providers.dart` only. No changes to `chat_screen.dart`.

---

## Acceptance Criteria

- [x] Poll timer cancels after 60 seconds of polling (30 ticks)
- [x] Poll timer callback checks `mounted` at entry and after each `await`
- [x] Poll timer prevents overlapping async callbacks via `_isPolling` guard
- [x] All 7 transient fields reset via `_resetTransientState()` in `prepareForSessionSwitch`, `clearSession`, and `dispose`
- [x] `_reattachStreamContent` cleared at start of `_reattachToBackgroundStream`
- [x] `loadSession` checks `state.sessionId != sessionId` before final state write
- [ ] No regressions in normal streaming flow (send message → stream → complete)
- [ ] No regressions in session switching (switch during streaming, switch during idle)
- [x] App builds cleanly (`flutter analyze` — 0 errors)

---

## Out of Scope

- Visual indicator for poll timeout (deferred — open question from brainstorm)
- `sessionUnavailable` timing edge case (very low severity, no functional change needed)
- BackgroundStreamManager `aborted` terminal event handling (separate concern)
- Exponential backoff for poll timer (performance optimization — file as follow-up if needed)
- Combining `hasActiveStream` + `getSessionTranscript` into single endpoint (server-side optimization)
- Extracting `StreamingContext` class for transient state (architectural improvement — follow-up issue)
- Migrating from `StateNotifier` to `Notifier` (Riverpod modernization — separate effort)
- Moving `Throttle` class out of `logging_service.dart` to a utility file (cleanup — separate PR)
- ChatScreen subscription defensive assertion (Fix 5 from original plan — dropped, code is already correct)

---

## References

- Brainstorm: `docs/brainstorms/2026-02-16-chat-stream-lifecycle-fixes-brainstorm.md`
- Issue: [#48](https://github.com/OpenParachutePBC/parachute-computer/issues/48)
- Key file: `app/lib/features/chat/providers/chat_message_providers.dart` (1739 lines)
- Throttle class: defined in `core/services/logging_service.dart` (~line 457) — has `reset()` method
- PR #57 (mid-stream messaging) — recently merged, changes in same files
- Existing `mounted` usage: `sync_provider.dart:393,462` (`SyncNotifier`)
- Existing cleanup helper pattern: `streaming_transcription_provider.dart` (`_stopDurationTimer()`)
- `StateNotifier.mounted` available since `state_notifier` 0.7.0
- Dart timer async overlap: callbacks can interleave when `await` takes longer than interval
