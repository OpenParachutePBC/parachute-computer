# Mid-Stream Session Shows Stop Button But Content Doesn't Update

**Type:** Bug
**Component:** app (chat streaming)
**Priority:** P1
**Affects:** Real-time updates, multi-session workflows

---

## Problem

When opening a chat session that's actively streaming, the UI correctly shows the stop button (indicating it knows streaming is active), but content doesn't update in real-time. User must manually refresh to see progress.

**Current behavior:**
1. Session A is streaming in background
2. User navigates to Session A
3. UI shows stop button (✓ correct)
4. Content appears frozen - no real-time updates (✗ broken)
5. User clicks stop/refresh to see current state

**Expected behavior:**
- Content should update automatically in real-time
- No manual refresh needed
- Smooth reconnection to ongoing stream

---

## Root Cause

The app has **two modes** for handling mid-stream sessions:

### Mode 1: Reattach (Real-Time) ✓
**When:** Stream exists in `BackgroundStreamManager` (app hasn't been killed)
**How:** Reattaches to broadcast controller, receives SSE events
**Result:** Real-time updates, smooth UX

### Mode 2: Polling (Delayed) ✗
**When:** Server reports active stream but local manager doesn't have it
**How:** Polls every 2 seconds, reloads transcript via HTTP GET
**Result:** Discrete snapshots, appears frozen between polls

**The bug:** App enters Polling Mode even when it should be in Reattach Mode.

---

## Technical Details

### Detection Flow

**Code location:** `app/lib/features/chat/providers/chat_message_providers.dart:322-483`

```dart
// loadSession() logic
final hasActiveStream = _streamManager.hasActiveStream(sessionId);  // Local check
final serverStreamCheckFuture = _service.hasActiveStream(sessionId);  // Server check

// Later...
final serverHasActiveStream = await serverStreamCheckFuture;
if (serverHasActiveStream && !hasActiveStream) {
  hasActiveStream = true;  // Enters polling mode
}
```

**Problem scenarios:**

1. **Race condition:** Server reports active before local manager registers it
2. **Broadcast stream closed:** Stream completed between detection and reattach
3. **Session ID mismatch:** Events dropped due to rapid session switching
4. **Transcript API limitation:** `getSessionTranscript(afterCompact: true)` not returning partial content during streaming

### Why Stop Button Shows

`isStreaming: true` is set when **either** local or server reports active stream (lines 382-387):

```dart
state = state.copyWith(
  isStreaming: hasActiveStream || serverHasActiveStream,
  // ...
);
```

### Why Content Doesn't Update

In Polling Mode (lines 579-651):
- Polls every 2 seconds: `_pollTimer = Timer.periodic(const Duration(seconds: 2), ...)`
- Reloads transcript: `_loadSessionTranscript(sessionId, afterCompact: true)`
- **Issue:** Transcript API may not return incremental updates during streaming
- **Issue:** 2-second delay creates perceived "frozen" state
- **Issue:** Polls max 30 times (60 seconds) then stops

### Reattach Logic

When local stream exists (lines 551-570):

```dart
_currentStreamSubscription = await _streamManager.reattachCallback(
  sessionId: sessionId,
  onEvent: _handleStreamEvent,
  onDone: () { /* ... */ },
  onError: (error) { /* ... */ },
);
```

**If this returns null:** No active stream, but server may still report active → enters polling

---

## User Impact

**Severity:** High
- Breaks multi-session workflows (common on desktop, mobile with background tabs)
- Forces manual refreshes to see progress
- Creates confusion ("is it working?")
- Especially problematic for long-running tasks (file processing, research)

**Frequency:** Very Common
- Happens every time user switches away from streaming session
- Mobile: Background app → foreground
- Desktop: Switch tabs → return
- Any navigation away from active session

---

## Reproduction Steps

1. Start a long-running task in Session A (e.g., file analysis, web research)
2. Immediately switch to Session B (or minimize app)
3. Wait 5+ seconds for streaming to continue
4. Return to Session A
5. **Observe:** Stop button shows, but content is frozen at old state
6. Click anywhere or refresh → content jumps to current state

---

## Proposed Solutions

### Option A: Eliminate Polling Mode (Recommended)

**Always maintain SSE connection, even in background:**

- Don't close SSE streams when navigating away
- `BackgroundStreamManager` keeps all streams alive until completion
- Reattach is always instant and real-time
- No fallback to polling

**Implementation:**
1. Change `prepareForSessionSwitch()` to NOT cancel stream subscription
2. Keep `_activeStreams` populated for all background sessions
3. Memory management: Limit max background streams (e.g., 5 concurrent)
4. Oldest streams auto-close when limit exceeded

**Pros:**
- True real-time updates across all sessions
- No polling overhead
- Simpler code - remove polling logic
- Better UX - instant reconnection

**Cons:**
- Higher memory usage (multiple SSE connections)
- Need stream limit to prevent resource exhaustion
- Doesn't solve app restart case (see Option B)

### Option B: Aggressive Polling with Incremental Updates

**Make polling mode work better:**

- Poll more frequently (500ms instead of 2s)
- Ensure transcript API returns partial content during streaming
- Show visual indicator: "Syncing..." during poll cycles
- Extend max poll time (300 ticks = 5 minutes instead of 60 seconds)

**Implementation:**
1. Reduce poll interval: `Duration(milliseconds: 500)`
2. Server: Ensure `getSessionTranscript()` flushes events during stream
3. Add loading indicator during polls
4. Increase max ticks: `const maxPolls = 300`

**Pros:**
- Works across app restarts
- Handles edge cases (stream lost, server disconnect)
- Simpler than maintaining multiple SSE connections

**Cons:**
- Still not true real-time (500ms lag)
- More API calls (2/sec instead of 1/2sec)
- Polling feels hacky compared to proper reconnection

### Option C: Hybrid - Reattach + Smarter Polling

**Combine both approaches:**

- **Primary:** Always reattach to local streams (Option A)
- **Fallback:** Better polling for app restarts (Option B)
- **Server-Sent Events for Reconnection:** Server emits `stream_started` event when stream begins
  - Client can listen to global SSE channel: `/api/events`
  - When stream starts, client creates new connection
  - Enables reconnection even after app restart

**Implementation:**
1. Maintain background streams during navigation (Option A)
2. Add global event channel for stream lifecycle
3. Client subscribes on startup, creates connections as needed
4. Fallback to fast polling (500ms) if SSE unavailable

**Pros:**
- Best UX - real-time when possible
- Robust - handles all edge cases
- Works after app restarts
- Graceful degradation

**Cons:**
- Most complex implementation
- Requires server changes (global event channel)
- More connection management

---

## Recommendation

**Implement Option A: Eliminate Polling Mode**

**Why:**
1. **Simplest solution** - remove problematic polling logic
2. **Best UX** - true real-time updates, no lag
3. **Handles 90% of cases** - navigation within app session
4. **YAGNI** - app restart case is rare, can add later if needed

**Implementation plan:**
1. Change `prepareForSessionSwitch()` to NOT cancel subscriptions
2. Keep `BackgroundStreamManager._activeStreams` populated for all active sessions
3. Implement stream limit (e.g., max 5 concurrent background streams)
4. Oldest streams auto-close when limit hit
5. Remove polling fallback code (or mark as "future enhancement")

**For app restart case:**
- Accept limitation: polling fallback works acceptably for rare case
- Or: Add Option C's global event channel in future iteration

---

## Success Criteria

- [ ] User navigates to mid-stream session → content updates immediately
- [ ] No manual refresh needed to see current state
- [ ] Stop button shows AND content streams in real-time
- [ ] Works across session switches (A → B → A)
- [ ] Memory usage stays bounded (stream limit enforced)
- [ ] Visual indicator shows "reconnecting" if fallback needed

---

## Related Issues

- Related to AskUserQuestion persistence (#70) - both involve state loss during navigation
- Part of larger "chat state persistence" improvements
- May relate to message deduplication (if events replay on reattach)

---

## Files to Modify

**Frontend (app/):**
- `lib/features/chat/providers/chat_message_providers.dart` - prepareForSessionSwitch, loadSession, polling logic
- `lib/features/chat/services/background_stream_manager.dart` - Stream lifecycle, limit enforcement
- `lib/features/chat/screens/chat_screen.dart` - Visual indicator for reconnection state

**Backend (computer/):**
- `parachute/core/orchestrator.py` - Ensure `active_streams` tracking is accurate
- `parachute/api/chat.py` - Stream status endpoint, transcript API incremental updates

**Tests:**
- Session switch during streaming
- Multiple concurrent streams
- Stream limit enforcement
- App restart with active stream (polling fallback)

---

## Open Questions

1. **What's the right stream limit?**
   - 5 concurrent streams? 10? Unlimited?
   - Should be configurable or hardcoded?
   - What happens when limit exceeded - close oldest or reject new?

2. **Should polling fallback be removed entirely?**
   - Or kept for app restart case?
   - If kept, how frequent should polls be?

3. **How to handle events that arrive during session switch?**
   - Buffer them? Replay them? Drop them?
   - Current code has guard: `if (state.sessionId != sessionId) return;`

4. **Should there be a visual indicator for "reconnecting"?**
   - Show spinner or "syncing" message?
   - Or just silently reconnect and show stop button?
