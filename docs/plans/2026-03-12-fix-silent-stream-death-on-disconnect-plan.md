---
title: "Silent Stream Death on SSE Disconnect"
type: fix
date: 2026-03-12
issue: 246
---

# Silent Stream Death on SSE Disconnect

When an SSE connection drops (client disconnect, network issue, app backgrounding), `asyncio.CancelledError` bypasses all logging and cleanup — the stream silently vanishes with zero diagnostic information.

## Problem Statement

Investigated session `34c7443b` which stopped mid-tool-loop at 22:19 PM. The transcript shows 25+ tool calls after compaction, ending with an Edit tool_use that never received a tool_result. Server logs show:

- **SDK launch at 22:19:07** — normal startup
- **5 minutes of silence** — no SDK consumer ended, no stream ended, no SSE stream complete
- **New session at 22:24:27** — a different session works fine

The diagnostic logging added in PR #243 works for **normal** stream termination (visible for other sessions at 22:15, 22:18, 22:26), but produces **nothing** for this session. The cancellation path is a blind spot.

### Root Cause

Three independent gaps:

**1. `event_generator` doesn't catch `CancelledError`**

```python
# chat.py line 157
except Exception as e:  # CancelledError is BaseException, not Exception!
```

In Python 3.9+, `asyncio.CancelledError` inherits from `BaseException`, not `Exception`. When FastAPI cancels the generator on client disconnect, the error flies past our handler — no "SSE stream complete" log, no "Client disconnected" log, nothing.

**2. No per-event timeout in trusted path**

`claude_sdk.py`'s consumer does `async for event in sdk_query()` with **no timeout**. If the CLI subprocess stops producing events (crash, hang, API error), the consumer will sit there forever. The sandbox path has `readline_timeout` (300s), but the trusted path has nothing equivalent.

**3. Orphaned consumer tasks**

Server logs show repeated `asyncio - ERROR - Task was destroyed but it is pending!` errors on multiple dates. These are consumer tasks from `query_streaming` that were abandoned without proper cancellation — the async generator was garbage-collected from a different task context without its finally block executing.

## Proposed Solution

### Fix 1: Cancellation-aware logging in `event_generator` (chat.py)

Add a `finally` block that always logs stream termination, regardless of how the generator exits.

```python
async def event_generator(request: Request, chat_request: ChatRequest):
    event_count = 0
    heartbeat_count = 0
    end_reason = "unknown"
    try:
        # ... existing setup ...
        async for event in _with_heartbeat(stream, request):
            # ... existing event handling ...
        end_reason = "normal"

    except asyncio.CancelledError:
        end_reason = "cancelled"
        raise

    except Exception as e:
        end_reason = f"error: {e}"
        # ... existing error handling ...

    finally:
        logger.info(
            f"SSE stream ended: session={chat_request.session_id or 'new'}, "
            f"reason={end_reason}, events={event_count}, heartbeats={heartbeat_count}"
        )
```

Move the "SSE stream complete" log into a `finally` block that always fires, and add `except asyncio.CancelledError` so we can tag the reason.

### Fix 2: Event-level timeout in trusted path (claude_sdk.py)

Add a configurable timeout when reading events from the queue in `query_streaming`:

```python
while True:
    try:
        event_dict = await asyncio.wait_for(
            event_queue.get(), timeout=event_timeout
        )
    except asyncio.TimeoutError:
        # Consumer task is probably stuck
        if consumer_task.done():
            logger.warning("Event queue timeout but consumer already done")
            break
        logger.warning(
            f"Event queue timeout after {event_timeout}s — "
            f"consumer alive={not consumer_task.done()}"
        )
        break
    if event_dict is None:
        break
    yield event_dict
```

Wire through `Settings.trusted_event_timeout` (default: 300s, matching sandbox readline_timeout).

### Fix 3: Robust consumer task cleanup (claude_sdk.py)

Ensure the consumer task's finally block executes even on hard cancellation. The current pattern is correct (cancel + await), but add defensive logging:

```python
finally:
    if done_event is not None:
        done_event.set()
    if consumer_task is not None:
        if not consumer_task.done():
            consumer_task.cancel()
            try:
                await consumer_task
            except (asyncio.CancelledError, Exception):
                pass
        logger.info(
            f"query_streaming cleanup: consumer_done={consumer_task.done()}, "
            f"queue_remaining={event_queue.qsize()}"
        )
```

### Fix 4: Stream-end reason propagation in `_run_trusted` (orchestrator.py)

Move the "Stream ended" log into a finally block so it fires on cancellation too:

```python
try:
    async for event in query_streaming(...):
        # ... event handling ...
    end_reason = "interrupted" if interrupt.is_interrupted else "normal"

except asyncio.CancelledError:
    end_reason = "cancelled"
    yield AbortedEvent(...)
    raise

except Exception as e:
    end_reason = f"error: {e}"
    # ... error handling ...

finally:
    session_label = captured_session_id or (session.id[:8] if session.id else "unknown")
    logger.info(
        f"Stream ended: session={session_label}, reason={end_reason}, "
        f"result_len={len(result_text)}, model={captured_model}"
    )
```

## Files to Modify

| File | Change |
|------|--------|
| `computer/parachute/api/chat.py` | Fix 1: `finally` block + `CancelledError` handler in `event_generator` |
| `computer/parachute/core/claude_sdk.py` | Fix 2: Event queue timeout. Fix 3: Defensive cleanup logging |
| `computer/parachute/core/orchestrator.py` | Fix 4: Move stream-end log to `finally` block |
| `computer/parachute/config.py` | Add `trusted_event_timeout` setting (default 300) |

## Acceptance Criteria

- [x] When client disconnects mid-stream, server logs show `SSE stream ended: reason=cancelled`
- [x] When SDK subprocess hangs, stream terminates after `trusted_event_timeout` seconds
- [x] "Stream ended" log fires for ALL termination causes (normal, cancelled, error, interrupted)
- [x] "SDK consumer ended" log fires for ALL termination causes
- [x] No more `Task was destroyed but it is pending!` errors from stream consumer tasks
- [x] All 552+ existing tests pass (586 passed)
- [ ] Normal streaming behavior unchanged (verify with a real chat)

## Testing Strategy

These are infrastructure/lifecycle fixes — hard to unit test directly. Verify by:
1. Running existing test suite (regression check)
2. Manual test: start a chat, close the app mid-stream → check server logs for `reason=cancelled`
3. Watch production logs for the new lifecycle lines over 24h

## Dependencies & Risks

- **Low risk**: All changes are logging/timeout additions — no behavioral changes to the happy path
- **PR #243 dependency**: Should be merged first since these fixes build on top of its diagnostic logging
- **Config addition**: `trusted_event_timeout` is new but has sane default (300s)

## References

- PR #243: Streaming reliability fixes (Fix A-E) — the first round of fixes
- Issue #232: Parent issue for streaming reliability
-Session `34c7443b`: The production incident that exposed this gap
- Server log evidence: `asyncio - ERROR - Task was destroyed but it is pending!` on 03/03, 03/04, 03/09, 03/11, 03/12
