# Bot Connector Resilience — Reconnection, Health, and Lifecycle

**Status**: Brainstorm complete, ready for planning
**Priority**: P2 (Server reliability)
**Modules**: computer

---

## What We're Building

Make Telegram and Discord bot connectors resilient to transient failures. Today, when a connector's polling loop or WebSocket client hits an exception, it logs the error and dies silently. No reconnection, no health data, no notification. The user discovers their bot is down only when messages stop arriving.

### Specific Gaps

1. **No reconnection with backoff** — `TelegramConnector._poll()` catches exceptions and logs them but doesn't retry. `DiscordConnector._run_client()` has the same pattern. Both set `_running = False` and exit.

2. **Minimal health data** — The `/api/bots/status` endpoint reports only `_running: bool`. No failure count, no last error, no uptime, no last successful message timestamp. The `_on_connector_error` callback in `bots.py` (line 220) logs the crash and removes the connector from `_connectors`, but doesn't track why it crashed.

3. **Inconsistent async task lifecycle** — `asyncio.create_task()` results aren't consistently tracked. `stop()` cancels but may not await completion. Race condition on `_running` flag between the polling loop and `stop()`.

4. **No notification when connector goes down** — Nothing fires when a connector crashes. The hook system (`core/hooks/`) exists but no `bot.connector.*` events are defined.

---

## Why This Approach

### Both Connectors Share the Same Shape

`TelegramConnector` and `DiscordConnector` have near-identical lifecycle patterns: `start()` creates a task, the task runs a loop, exceptions kill the loop, `stop()` cancels the task. A shared base class or mixin could handle reconnection, health tracking, and lifecycle, but both connectors are simple enough that duplicating the pattern (with minor variations) is cleaner than premature abstraction.

### The Hook System Is Ready

`core/hooks/runner.py` already supports firing events like `session.start`, `session.end`, etc. Adding `bot.connector.down` and `bot.connector.reconnected` events is straightforward — define the event names and call `hook_runner.fire()` at the right points.

### Health Data Enables App-Side UX

If `/api/bots/status` returns rich health data (failure count, last error, last reconnect, uptime), the Flutter app can poll this and show a banner when a connector is struggling. No push notification needed — the app already polls for pairing requests.

---

## Key Decisions

### 1. Add Reconnection with Exponential Backoff

**Decision**: Wrap the main loop in each connector with a retry loop. On exception, wait with exponential backoff (1s, 2s, 4s, 8s, ... capped at 60s) and retry. After N consecutive failures (default: 10), give up and mark the connector as `failed` (not just `not running`).

```python
async def _run_with_reconnect(self):
    backoff = 1
    failures = 0
    max_failures = 10
    while self._running and failures < max_failures:
        try:
            await self._run_loop()  # The actual polling/client loop
            break  # Clean exit
        except asyncio.CancelledError:
            break
        except Exception as e:
            failures += 1
            self._last_error = str(e)
            self._last_error_time = time.time()
            self._failure_count += 1
            logger.error(f"Connector error ({failures}/{max_failures}): {e}")
            if failures < max_failures:
                await asyncio.sleep(min(backoff, 60))
                backoff *= 2
    if failures >= max_failures:
        self._status = "failed"
        # Fire hook event
```

### 2. Add Rich Health Data to Status Endpoint

**Decision**: Add health fields to each connector instance, exposed via `/api/bots/status`:

- `status`: `"running"` | `"reconnecting"` | `"failed"` | `"stopped"`
- `failure_count`: Total failures since last clean start
- `last_error`: String of last exception
- `last_error_time`: Timestamp of last error
- `uptime`: Seconds since last clean start
- `last_message_time`: Timestamp of last successfully processed message
- `reconnect_attempts`: Current consecutive retry count

The health endpoint already exists and just needs richer data from the connector instances.

### 3. Fire Hook Events on Connector State Changes

**Decision**: Define two new hook events:
- `bot.connector.down` — Fired when a connector exhausts retries and enters `failed` state. Payload: platform, error, failure count.
- `bot.connector.reconnected` — Fired when a connector successfully reconnects after failures. Payload: platform, downtime duration.

Users can wire these to shell scripts in `vault/.parachute/hooks/` for custom notifications (email, Slack, etc.).

### 4. Fix Async Task Lifecycle

**Decision**:
- Track the task returned by `asyncio.create_task()` on the connector instance
- `stop()` should set `_running = False`, cancel the task, AND `await` it (with a timeout)
- Use an `asyncio.Event` for clean shutdown signaling instead of relying on `_running` flag checks in the loop
- The `_on_connector_error` callback should update connector status rather than removing it from `_connectors`

---

## Open Questions

### 1. Should we add a base class for connector lifecycle?
Both connectors share the reconnect/health/lifecycle pattern. A `BaseConnector` class could encapsulate this. **Recommendation**: Not yet — the connectors have different underlying libraries (python-telegram-bot vs discord.py) with different async patterns. Extract a base class only if a third connector is added.

### 2. Should the app show real-time connector health?
The app could poll `/api/bots/status` on the bot management screen and show reconnection status in real time. **Recommendation**: Yes, but as a separate app-side enhancement. The server changes are independent.

### 3. What should happen to in-flight messages during reconnection?
If a message arrives during the reconnection window, it's lost. Telegram's `getUpdates` offset tracking means missed updates can be replayed on reconnect, but Discord's gateway resume has more nuance. **Recommendation**: Accept message loss during reconnection for now. Document it as a known limitation.

---

## Files to Modify

| File | Changes |
|------|---------|
| `computer/parachute/connectors/telegram.py` | Add reconnection loop, health tracking fields, clean shutdown via Event |
| `computer/parachute/connectors/discord_bot.py` | Same pattern as Telegram |
| `computer/parachute/api/bots.py` | Enrich `/api/bots/status` with health data; update `_on_connector_error` to track status |
| `computer/parachute/core/hooks/runner.py` | Register `bot.connector.down` and `bot.connector.reconnected` event types |

---

## Success Criteria

- Connector automatically reconnects after transient network failure (verify by killing network briefly)
- `/api/bots/status` reports `reconnecting` state during backoff, `failed` after max retries
- `bot.connector.down` hook fires when connector gives up
- `stop()` cleanly shuts down within 5 seconds (no orphaned tasks)
- No message loss on short (<5s) network interruptions for Telegram (offset-based replay)
