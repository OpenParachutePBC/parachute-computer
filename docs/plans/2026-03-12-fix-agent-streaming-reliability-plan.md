---
title: "Agent Streaming Reliability: Stop Random Stopping"
type: fix
date: 2026-03-12
issue: 232
---

# Agent Streaming Reliability: Stop Random Stopping

Agents randomly stop mid-task in both trusted and sandboxed chats. Investigation traced this to multiple independent causes — the highest-impact being AskUserQuestion blocking the stream invisibly for up to 5 minutes.

## Problem Statement

Users report the agent "stops at random places" during chats. The response either freezes (agent appears stuck) or truncates (partial content, no error). This happens in both trusted and sandboxed execution paths.

**Root causes identified (from server logs + code analysis):**

1. **AskUserQuestion blocks stream invisibly (P0)** — When the model calls AskUserQuestion, the permission handler blocks the SDK stream for up to 5 minutes. The question renders inline in the message bubble, but if the user doesn't notice it (scrolled away, different tab, backgrounded app), the agent appears completely frozen. Server logs show `AskUserQuestion timeout` events on active sessions today.

2. **Last text update lost on done event (P1)** — `_handleSendStreamEvent`'s `done` case doesn't flush throttled updates before setting `isStreaming: false`. Final characters of a response can be silently dropped.

3. **No diagnostic logging for stream lifecycle (P1)** — When streams end, we have no visibility into WHY. Logs show SDK launches but not stream terminations, making debugging impossible without code archaeology.

4. **Async task leaks (P2)** — `Task was destroyed but it is pending!` errors appear in batches in server logs. The `consumer_task` in `query_streaming` and `_bridge_task` in the orchestrator aren't always properly cancelled+awaited.

5. **Sandbox timeout too short (P2)** — 300-second (5-min) default times out during long operations like Android deploys. The 180-second per-line readline timeout is also tight. Server logs show repeated sandbox timeouts for the same session.

## Acceptance Criteria

- [x] Toast/OS notification fires when AskUserQuestion arrives and user isn't looking at the chat
- [x] Auto-scroll to question when it first appears in the active chat
- [x] Final throttled text update is flushed before done event processing
- [x] Server logs show stream start, end, and reason for every chat interaction
- [x] No `Task was destroyed but it is pending!` warnings in server logs
- [x] Sandbox timeout configurable, default increased to 600s
- [x] Readline timeout increased from 180s to 300s

## Proposed Solution

### Fix A — AskUserQuestion Notification (P0)

**Files:**
- `app/lib/features/chat/providers/agent_completion_provider.dart` — Add `AgentQuestionNotifier` (parallel to existing `AgentCompletionNotifier`)
- `app/lib/features/chat/providers/chat_message_providers.dart` — Fire question notification from `userQuestion` event handler
- `app/lib/features/chat/screens/chat_screen.dart` — Listen for question events, auto-scroll to bottom

**Approach:** Mirror the existing `agentCompletionProvider` pattern:
- `AgentQuestionEvent` with sessionId, questions, timestamp
- `AgentQuestionNotifier.onQuestion()` — decides surface based on app state:
  - Viewing that session → auto-scroll to bottom (question is inline)
  - Different session/tab → show toast "Claude has a question" with tap-to-navigate
  - App backgrounded → OS notification via `NotificationService`
- Wire into `_handleSendStreamEvent` and `_handleStreamEvent` (reattach path) where `StreamEventType.userQuestion` is processed
- The toast should be tappable → navigates to the session and scrolls to bottom

### Fix B — Flush Pending Updates on Done (P1)

**Files:**
- `app/lib/features/chat/providers/chat_message_providers.dart`

**Change:** Add `_flushPendingUpdates()` as the first line of the `StreamEventType.done` case in `_handleSendStreamEvent` (around line 1530). One-line fix.

### Fix C — Diagnostic Logging (P1)

**Files:**
- `computer/parachute/core/orchestrator.py` — `_run_trusted` and `_run_sandboxed`
- `computer/parachute/core/claude_sdk.py` — `query_streaming` and `_consume_sdk`
- `computer/parachute/api/chat.py` — `event_generator`

**Log points to add:**
1. `_run_trusted`: after `async for` loop ends — log whether it was interrupt, normal end, or error. Log `result_text` length, `captured_session_id` presence, `captured_model`.
2. `_consume_sdk`: when consumer task ends — log reason (result received, error type, cancelled). Log event count.
3. `event_generator`: when generator exits — log reason (disconnect, normal, error).
4. `query_streaming` finally block: log queue drain stats, consumer_task state.

Format: `logger.info(f"Stream ended: session={sid[:8]}, reason={reason}, events={count}, result_len={len(result_text)}")` — one line per stream lifecycle, greppable.

### Fix D — Task Leak Cleanup (P2)

**Files:**
- `computer/parachute/core/claude_sdk.py` — `query_streaming` finally block
- `computer/parachute/api/chat.py` — `_with_heartbeat` finally block

**Changes:**
1. In `query_streaming` finally: after `consumer_task.cancel()`, add `await asyncio.gather(consumer_task, return_exceptions=True)` to properly await cancellation
2. In `_with_heartbeat` finally: after `next_task.cancel()`, add `try: await next_task except (asyncio.CancelledError, StopAsyncIteration): pass`
3. For `_bridge_task`: these are intentionally fire-and-forget — no change needed, the done_callback already handles errors

### Fix E — Configurable Timeouts (P2)

**Files:**
- `computer/parachute/core/sandbox.py` — `AgentSandboxConfig`
- `computer/parachute/core/orchestrator.py` — `_run_sandboxed`
- `computer/parachute/config.py` — add settings

**Changes:**
1. `AgentSandboxConfig.timeout_seconds` default: 300 → 600 (10 minutes)
2. Readline timeout in `_stream_process`: 180 → 300 seconds
3. Add `sandbox_timeout` and `sandbox_readline_timeout` to `Settings` (configurable via env vars)
4. `_run_sandboxed` passes settings values to `AgentSandboxConfig`

## Technical Considerations

- Fix A follows the existing `agentCompletionProvider` pattern exactly — same notification service, same toast mechanism, same app lifecycle checks
- Fix B is a one-liner with zero risk
- Fix C adds logging only, no behavior change — but the log format should be greppable and structured
- Fix D changes async cleanup ordering — needs testing to ensure no deadlocks (the `gather` with `return_exceptions=True` is safe)
- Fix E changes defaults — existing sessions may behave differently with longer timeouts (more resource usage, but better reliability)

## References

- PR #228 — Previous streaming reliability fixes (heartbeat, loadSession guard)
- `agentCompletionProvider` — Existing pattern for completion notifications
- Server logs at `~/Library/Logs/parachute/stdout.log` — Evidence of AskUserQuestion timeouts and task leaks
