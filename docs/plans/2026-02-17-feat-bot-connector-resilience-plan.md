---
title: "feat: Bot connector resilience — reconnection, health, and lifecycle"
type: feat
date: 2026-02-17
issue: "#55"
module: computer
priority: P2
deepened: 2026-02-17
---

# Bot Connector Resilience — Reconnection, Health, and Lifecycle

## Enhancement Summary

**Deepened on:** 2026-02-17
**Agents used:** python-reviewer, security-sentinel, performance-oracle, architecture-strategist, code-simplicity-reviewer, parachute-conventions-reviewer, pattern-recognition-specialist, best-practices-researcher

### Key Improvements from Research
1. **Move `_run_with_reconnect()` to base class** — eliminates duplication, uses Template Method pattern with abstract `_run_loop()`
2. **Add jitter to exponential backoff** — prevents thundering herd when both connectors recover simultaneously (AWS Full Jitter algorithm)
3. **Use `ConnectorState` StrEnum** — enforces valid state transitions, prevents typo bugs
4. **Sanitize error messages** — prevent token/path leakage in `last_error` field exposed via API
5. **Add `_fire_hook()` helper** — replaces fragile `hasattr` checks, centralizes hook access
6. **Add `mark_failed()` public method** — fixes encapsulation violation where `_on_connector_error` directly mutates private state
7. **Use `time.monotonic()` for uptime** — immune to system clock changes
8. **Use `HookEvent` enum members** — not raw strings, prevents typo bugs
9. **Distinguish fatal vs transient errors** — `InvalidToken` and `LoginFailure` skip retry loop entirely

### Deferred (Not in This PR)
- Pydantic `ConnectorStatus` model for status property (follow-up cleanup)
- Typed `ServerRef` Protocol replacing `SimpleNamespace` (follow-up cleanup)
- Module-level state refactor in `bots.py` to `app.state` (follow-up cleanup)

## Overview

Make Telegram and Discord bot connectors resilient to transient failures. Today, when a connector's polling loop or WebSocket client hits an exception, it logs the error and dies silently. The user discovers their bot is down only when messages stop arriving.

This plan adds exponential-backoff reconnection with jitter, rich health data on the status endpoint, hook events for connector state changes, and fixes the async task lifecycle so `stop()` is clean and reliable.

## Problem Statement

Four specific gaps exist in the current connector implementation:

1. **No reconnection** — `TelegramConnector._poll()` (`telegram.py:101-109`) catches exceptions, logs them, sets `_running = False`, and exits. `DiscordConnector._run_client()` (`discord_bot.py:108-116`) does the same. No retry, no backoff, no notification.

2. **Minimal health data** — `/api/bots/status` (`bots.py:67-93`) reports only `running: bool`. No failure count, last error, uptime, or last message timestamp. The `_on_connector_error` callback (`bots.py:220-226`) logs crashes and removes the connector from `_connectors`, but this callback only fires on `start()` failures — not on inner loop failures.

3. **Broken async lifecycle** — Discord's `asyncio.create_task(self._run_client())` (`discord_bot.py:104`) never stores the task reference. Telegram stores it but `stop()` cancels without awaiting (`telegram.py:111-121`). The `_running` flag has no synchronization between the loop and `stop()`.

4. **No notifications** — The hook system (`core/hooks/`) is fully built and tested but `fire()` is never called in production. No `bot.connector.*` events exist.

## Proposed Solution

### Phase 1: State Enum and Health Tracking on Base Class

Add a `ConnectorState` StrEnum and health state fields to `BotConnector` in `base.py`.

**File: `computer/parachute/connectors/base.py`**

Add the state enum (top of file or in a separate `types.py` if preferred):

```python
import time
import random
from enum import StrEnum

class ConnectorState(StrEnum):
    STOPPED = "stopped"
    RUNNING = "running"
    RECONNECTING = "reconnecting"
    FAILED = "failed"
```

Add instance variables in `__init__`:

```python
# Health tracking
self._status: ConnectorState = ConnectorState.STOPPED
self._failure_count: int = 0
self._last_error: str | None = None
self._last_error_time: float | None = None
self._started_at: float | None = None  # monotonic clock
self._last_message_time: float | None = None  # wall clock for display
self._reconnect_attempts: int = 0
self._stop_event: asyncio.Event = asyncio.Event()
self._task: asyncio.Task | None = None
```

#### Research Insight: State Machine Enforcement

Multiple reviewers flagged the need for validated state transitions. Add a transition method:

```python
_VALID_TRANSITIONS: ClassVar[dict[ConnectorState, set[ConnectorState]]] = {
    ConnectorState.STOPPED: {ConnectorState.RUNNING},
    ConnectorState.RUNNING: {ConnectorState.STOPPED, ConnectorState.RECONNECTING, ConnectorState.FAILED},
    ConnectorState.RECONNECTING: {ConnectorState.RUNNING, ConnectorState.FAILED, ConnectorState.STOPPED},
    ConnectorState.FAILED: {ConnectorState.STOPPED, ConnectorState.RUNNING},
}

def _set_status(self, new: ConnectorState) -> None:
    old = self._status
    if new not in self._VALID_TRANSITIONS.get(old, set()):
        logger.warning(f"Invalid connector state transition: {old} -> {new}")
        return
    self._status = new
    # Keep _running in sync for backwards compatibility
    self._running = new == ConnectorState.RUNNING
```

Update the existing `status` property (`base.py:346-353`) to return enriched data:

```python
@property
def status(self) -> dict:
    return {
        "platform": self.platform,
        "status": self._status.value,
        "running": self._status == ConnectorState.RUNNING,
        "failure_count": self._failure_count,
        "last_error": self._last_error,
        "last_error_time": self._last_error_time,
        "uptime": (time.monotonic() - self._started_at) if self._started_at and self._status == ConnectorState.RUNNING else None,
        "last_message_time": self._last_message_time,
        "reconnect_attempts": self._reconnect_attempts,
        "allowed_users_count": len(self.allowed_users),
    }
```

#### Research Insight: Use `time.monotonic()` for Uptime

`time.monotonic()` is immune to system clock changes (NTP adjustments, manual clock set). Use it for uptime calculation. Keep `time.time()` only for `last_message_time` and `last_error_time` (human-readable timestamps).

#### Research Insight: Centralized Hook Helper

Replace fragile `hasattr` checks with a helper on the base class:

```python
async def _fire_hook(self, event: str, context: dict[str, Any]) -> None:
    """Fire a hook event if the hook runner is available."""
    hook_runner = getattr(self.server, "hook_runner", None)
    if hook_runner:
        await hook_runner.fire(event, context)
```

#### Research Insight: Error Sanitization

The security review flagged that exception strings can leak tokens, paths, and internal state. Add sanitization:

```python
import re

_SENSITIVE_PATTERNS = [
    (re.compile(r"(bot|token)[\"']?\s*[:=]\s*[\"']?([a-zA-Z0-9:_-]{20,})", re.IGNORECASE), r"\1=<REDACTED>"),
    (re.compile(r"/[a-z0-9_.-]+/\.parachute/[^\s]+", re.IGNORECASE), "~/.parachute/<REDACTED>"),
]

def _sanitize_error(self, exc: Exception) -> str:
    """Sanitize exception message for safe API exposure."""
    exc_type = type(exc).__name__
    msg = str(exc)
    for pattern, repl in self._SENSITIVE_PATTERNS:
        msg = pattern.sub(repl, msg)
    return f"{exc_type}: {msg[:200]}"
```

#### Research Insight: Public `mark_failed()` Method

The architecture review flagged that `_on_connector_error` in `bots.py` directly mutates private state. Add a public method:

```python
def mark_failed(self, exc: Exception) -> None:
    """Mark connector as failed due to an external error (e.g., start() failure)."""
    self._set_status(ConnectorState.FAILED)
    self._last_error = self._sanitize_error(exc)
    self._last_error_time = time.time()
```
```

### Phase 2: Reconnection with Exponential Backoff + Jitter

**Key change from original plan**: Put `_run_with_reconnect()` on the **base class**, not duplicated per connector. Both connectors implement an abstract `_run_loop()` method.

**File: `computer/parachute/connectors/base.py`**

#### Research Insight: Full Jitter (AWS Recommended)

Plain exponential backoff (1s, 2s, 4s...) causes thundering herd when multiple connectors recover simultaneously. The AWS Architecture Blog recommends Full Jitter: `sleep = random(0, min(cap, base * 2^attempt))`.

```python
@abstractmethod
async def _run_loop(self) -> None:
    """Platform-specific connection loop. Raise on failure, return on clean exit."""
    ...

async def _run_with_reconnect(self) -> None:
    """Reconnection wrapper with exponential backoff + jitter. Shared across all connectors."""
    consecutive_failures = 0
    max_failures = 10

    while not self._stop_event.is_set() and consecutive_failures < max_failures:
        try:
            if consecutive_failures > 0:
                logger.info(f"{self.platform} connector reconnected after {consecutive_failures} attempt(s)")
                await self._fire_hook(
                    HookEvent.BOT_CONNECTOR_RECONNECTED,
                    {"platform": self.platform, "attempts": consecutive_failures},
                )
            consecutive_failures = 0
            self._reconnect_attempts = 0
            self._set_status(ConnectorState.RUNNING)
            self._started_at = time.monotonic()
            await self._run_loop()
            break  # Clean exit (stop_event set or updater stopped)
        except asyncio.CancelledError:
            raise  # Never swallow CancelledError
        except Exception as e:
            consecutive_failures += 1
            self._failure_count += 1
            self._reconnect_attempts = consecutive_failures
            self._last_error = self._sanitize_error(e)
            self._last_error_time = time.time()
            self._set_status(ConnectorState.RECONNECTING)
            logger.error(
                f"{self.platform} connector error ({consecutive_failures}/{max_failures}): {e}"
            )
            if consecutive_failures < max_failures:
                # Full Jitter: random(0, min(cap, base * 2^attempt))
                exp = min(60, 1.0 * (2 ** (consecutive_failures - 1)))
                delay = random.uniform(0, exp)
                # Interruptible sleep — stop() can wake us immediately
                try:
                    await asyncio.wait_for(
                        self._stop_event.wait(), timeout=delay
                    )
                    break  # stop_event was set during backoff
                except asyncio.TimeoutError:
                    pass  # Timeout expired, retry

    if consecutive_failures >= max_failures:
        self._set_status(ConnectorState.FAILED)
        logger.error(
            f"{self.platform} connector failed after {max_failures} attempts. "
            f"Last error: {self._last_error}"
        )
        await self._fire_hook(
            HookEvent.BOT_CONNECTOR_DOWN,
            {
                "platform": self.platform,
                "error": self._last_error,
                "failure_count": self._failure_count,
            },
        )
```

#### Research Insight: Reconnection Success Detection

The reconnection success hook fires at the **top of the loop** after a previous failure, not after `_run_loop()` returns. For Telegram, `start_polling()` blocks indefinitely while running — entering it without immediate exception IS success. The `consecutive_failures > 0` check at loop top correctly detects this.

#### Research Insight: `CancelledError` Must Propagate

The python-reviewer flagged that the original plan's `except asyncio.CancelledError: break` swallows the error. The correct pattern is `raise` — let the caller handle cancellation.

**File: `computer/parachute/connectors/telegram.py`**

Rename `_poll()` to `_run_loop()`:

```python
async def _run_loop(self) -> None:
    """Run Telegram long-polling. Returns when updater stops, raises on error."""
    await self._app.updater.start_polling(drop_pending_updates=True)
```

**File: `computer/parachute/connectors/discord_bot.py`**

Rename `_run_client()` to `_run_loop()`:

```python
async def _run_loop(self) -> None:
    """Run Discord gateway client. Returns on clean close, raises on error."""
    await self._client.start(self.bot_token, reconnect=False)
```

#### Research Insight: discord.py `reconnect=False` Details

With `reconnect=False`, discord.py still handles Discord-initiated reconnects (RESUME protocol, load-balancing disconnects every 15min-2hrs). It only disables automatic recovery from *network* errors (ISP blips, DNS failures, timeouts). This is exactly what we want — our wrapper handles network-level reconnection while Discord's internal RESUME handles protocol-level reconnection.

#### Research Insight: Fatal vs Transient Exceptions

While the brainstorm decided against exception classification, the security and best-practices reviews both flagged that retrying auth failures 10 times is wasteful and potentially harmful (burns API rate limits). Add minimal fatal error detection:

```python
# In _run_with_reconnect, inside the except Exception branch, before retry:
# Fast-fail on auth errors — no point retrying with a bad token
exc_name = type(e).__name__
if exc_name in ("InvalidToken", "LoginFailure", "Unauthorized", "Forbidden"):
    self._set_status(ConnectorState.FAILED)
    self._last_error = self._sanitize_error(e)
    self._last_error_time = time.time()
    logger.error(f"{self.platform} fatal auth error, not retrying: {e}")
    await self._fire_hook(
        HookEvent.BOT_CONNECTOR_DOWN,
        {"platform": self.platform, "error": self._last_error, "failure_count": 1},
    )
    return
```

This checks exception *class names* (not types) to avoid importing library-specific exceptions. Covers `telegram.error.InvalidToken`, `discord.LoginFailure`, and generic `Unauthorized`/`Forbidden`.

### Phase 3: Clean Async Lifecycle

Fix `start()` and `stop()` on both connectors.

**Telegram `start()`** — store task, use `_run_with_reconnect`:

```python
async def start(self) -> None:
    # ... existing initialization (build app, register handlers) ...
    self._stop_event.clear()
    self._set_status(ConnectorState.RUNNING)
    self._started_at = time.monotonic()
    self._task = asyncio.create_task(self._run_with_reconnect())
```

**Telegram `stop()`** — signal event, await task with timeout:

```python
async def stop(self) -> None:
    if self._status == ConnectorState.STOPPED:
        return  # Idempotent
    self._stop_event.set()
    # Stop the telegram application first
    if self._app:
        try:
            if self._app.updater and self._app.updater.running:
                await self._app.updater.stop()
            if self._app.running:
                await self._app.stop()
            await self._app.shutdown()
        except Exception as e:
            logger.warning(f"Error during Telegram app shutdown: {e}")
    # Await the background task with timeout
    if self._task and not self._task.done():
        self._task.cancel()
        try:
            await asyncio.wait_for(self._task, timeout=5.0)
        except (asyncio.TimeoutError, asyncio.CancelledError):
            pass
    self._task = None
    self._started_at = None
    self._set_status(ConnectorState.STOPPED)  # Set AFTER cleanup completes
```

#### Research Insight: Set Status AFTER Cleanup

The python-reviewer flagged that setting `_status = "stopped"` before awaiting task completion means a concurrent health check during shutdown will report `stopped` while the connector is still shutting down. Set the status only after cleanup succeeds.

**Discord `start()`** — same pattern, store task.

**Discord `stop()`** — same pattern: set stop_event, close client, await task, then set status.

#### Research Insight: Ordering Contract

Document this in a comment: "Set stop_event BEFORE cancelling task. The stop_event interrupts `wait_for()` in the backoff loop immediately. Task cancellation is a backup for cases where the inner loop doesn't check the event."

### Phase 4: Hook System Integration

**File: `computer/parachute/core/hooks/events.py`**

Add two new event types to the `HookEvent` enum:

```python
BOT_CONNECTOR_DOWN = "bot.connector.down"
BOT_CONNECTOR_RECONNECTED = "bot.connector.reconnected"
```

These are non-blocking events (not added to `BLOCKING_EVENTS`). Hook execution should not delay connector recovery.

#### Research Insight: Hook Event Naming Convention

The naming follows the existing convention: `bot.message.*` for bot message events, `bot.connector.*` for connector lifecycle events. Using the `HookEvent` enum (not raw strings) in connector code prevents typo bugs and makes events greppable.

**File: `computer/parachute/server.py`**

Add `hook_runner` to `server_ref` so connectors can access it:

```python
server_ref = SimpleNamespace(
    database=db,
    orchestrator=orchestrator,
    orchestrate=orchestrate,
    hook_runner=app.state.hook_runner,  # NEW
)
```

### Phase 5: Status Endpoint Enrichment

**File: `computer/parachute/api/bots.py`**

Update `/api/bots/status` to use the connector's enriched `status` property:

```python
# Replace the hardcoded telegram/discord sections with:
for platform in ("telegram", "discord"):
    config_section = getattr(config, platform, None)
    connector = _connectors.get(platform)
    result[platform] = {
        "enabled": config_section.enabled if config_section else False,
        "has_token": bool(getattr(config_section, "bot_token", None)),
        **(connector.status if connector else {
            "status": "stopped",
            "running": False,
            "failure_count": 0,
            "last_error": None,
            "last_error_time": None,
            "uptime": None,
            "last_message_time": None,
            "reconnect_attempts": 0,
            "allowed_users_count": 0,
        }),
    }
```

Fix `_on_connector_error` — use public method instead of mutating private state:

```python
def _on_connector_error(task: asyncio.Task) -> None:
    if task.cancelled():
        return
    exc = task.exception()
    if exc:
        logger.error(f"{platform} connector start() failed: {exc}")
        connector = _connectors.get(platform)
        if connector:
            connector.mark_failed(exc)
        # Don't remove from _connectors — keep it so status endpoint can report the failure
```

Guard `_start_platform()` against starting a connector that's already reconnecting:

```python
existing = _connectors.get(platform)
if existing and existing._status in (ConnectorState.RUNNING, ConnectorState.RECONNECTING):
    logger.warning(f"{platform} connector already active (status: {existing._status})")
    return
```

#### Research Insight: Concurrent Start Protection

The security review flagged a TOCTOU race where two concurrent `/api/bots/{platform}/start` calls both pass the status check. The existing `_config_lock` in `bots.py` should be used to serialize start operations. Verify that `_start_platform()` is called under the lock, or add one:

```python
async def _start_platform(platform: str) -> None:
    async with _config_lock:
        existing = _connectors.get(platform)
        if existing and existing._status in (ConnectorState.RUNNING, ConnectorState.RECONNECTING):
            return
        # ... rest of start logic ...
```

### Phase 6: Message Timestamp Tracking

Inline `self._last_message_time = time.time()` in message handlers (no separate helper method needed — it's a single line).

**Telegram** — in `_handle_text_message()` and `_handle_voice_message()` (after successful processing).

**Discord** — in `on_message` handler (after successful processing).

Both also update when sending responses back (after `send_reply()`).

### Phase 7: Tests

**File: `computer/tests/unit/test_bot_connectors.py`**

Add test cases:

1. **`test_health_status_fields`** — New connector has `status="stopped"`, all health fields at defaults
2. **`test_reconnection_success`** — Mock `_run_loop()` to fail twice then succeed. Verify `failure_count=2`, status transitions `running→reconnecting→running`, and `consecutive_failures` resets
3. **`test_reconnection_exhaustion`** — Mock `_run_loop()` to always fail. Verify status becomes `failed` after 10 attempts, `bot.connector.down` hook fires
4. **`test_stop_during_backoff`** — Start connector, trigger failure, call `stop()` during backoff sleep. Verify connector stops promptly (not after delay)
5. **`test_stop_idempotent`** — Call `stop()` twice on a stopped connector. No exception
6. **`test_enriched_status_property`** — After failures and recovery, verify all status fields have correct values
7. **`test_hook_fires_on_failure`** — Mock hook_runner, verify `bot.connector.down` called with correct payload
8. **`test_hook_fires_on_reconnection`** — Mock hook_runner, verify `bot.connector.reconnected` called with correct payload
9. **`test_start_rejects_active_connector`** — Verify starting an already-running connector is a no-op
10. **`test_fatal_auth_error_skips_retry`** — Mock `_run_loop()` to raise `InvalidToken`. Verify connector goes directly to `failed` without retrying
11. **`test_state_transition_validation`** — Verify invalid transitions (e.g., `stopped→reconnecting`) are rejected with warning log

Use `asyncio.Event` manipulation and `unittest.mock.AsyncMock` to control timing. Mock `_run_loop()` to avoid real network calls. Use `asyncio.wait_for` with short timeouts to prevent test hangs.

## Technical Considerations

### Discord.py Built-in Reconnection

With `reconnect=False`, discord.py still handles Discord-initiated reconnects via the RESUME protocol (load-balancing disconnects every 15min-2hrs). It only disables automatic recovery from *network* errors (ISP blips, DNS failures, timeouts). Our wrapper handles network-level reconnection; Discord's internal mechanism handles protocol-level reconnection.

### Exception Classification (Minimal)

For MVP, retry all exceptions except:
- `asyncio.CancelledError` — always propagate
- Auth failures (`InvalidToken`, `LoginFailure`, `Unauthorized`, `Forbidden`) — fast-fail to `failed` state

All other exceptions are retried with backoff. This avoids deep coupling to library-specific exception hierarchies while catching the most impactful fatal errors.

### Backoff Interruptibility

The backoff sleep uses `asyncio.wait_for(self._stop_event.wait(), timeout=delay)` instead of `asyncio.sleep(delay)`. This means `stop()` can interrupt backoff immediately by setting `_stop_event`, ensuring shutdown within seconds regardless of backoff position.

**Performance note**: `asyncio.wait_for` adds ~5µs overhead vs `asyncio.sleep` — negligible for a 1-60s sleep. The UX benefit (immediate shutdown vs waiting up to 60s) far outweighs the cost.

### Backoff Timing Analysis

Worst-case total time to failure with Full Jitter (10 retries):
- Expected delay per attempt: half the exponential cap (since jitter is uniform 0→cap)
- Expected total: ~0.5 + 1 + 2 + 4 + 8 + 16 + 30 + 30 + 30 + 30 ≈ **151.5 seconds (~2.5 minutes)**
- Maximum possible: 1 + 2 + 4 + 8 + 16 + 32 + 60×4 = **303 seconds (~5 minutes)**
- With jitter, actual times will be distributed between these bounds

### Hook Runner Safety

Connectors use the `_fire_hook()` helper which checks `getattr(self.server, "hook_runner", None)` before firing. This handles the case where `server_ref` was created before hook_runner was added (graceful degradation). Hooks are non-blocking — failures are logged to the hook runner's error deque, not propagated to the connector.

### Error Message Sanitization

The `_sanitize_error()` method strips bot tokens and vault paths from exception messages before storing in `_last_error`. This prevents information leakage through the `/api/bots/status` endpoint, which is accessible from localhost without authentication.

### State Machine

```
                start()
  stopped ──────────────> running
     ^                      |
     | stop()               | exception (transient)
     |                      v
     |                 reconnecting ──(success)──> running
     |                      |
     |                 (max failures)
     |                      |
     |  exception (fatal)   v
     |  running ─────────> failed
     |                      |
     +──── stop() ──────────+
```

`stop()` transitions to `stopped` from any state. `start()` works from `stopped` or `failed`. Fatal auth errors go directly from `running` to `failed` without entering `reconnecting`.

## Security Considerations

The `/api/bots/status` endpoint is protected by the global API key middleware. In `remote` mode (default), localhost requests bypass authentication but remote requests require a valid API key. The `last_error` field is sanitized via `_sanitize_error()` to strip tokens and internal paths.

Hook event payloads contain the sanitized `last_error` string. Hook scripts should still treat the `error` context field as potentially containing sensitive data and avoid using it in shell commands or external API calls without additional sanitization.

## Acceptance Criteria

- [x] Connector automatically reconnects after transient failure with exponential backoff + jitter (Full Jitter, capped at 60s)
- [x] After 10 consecutive failures, connector enters `failed` state and stops retrying
- [x] Fatal auth errors (`InvalidToken`, `LoginFailure`) skip retry loop and fail immediately
- [x] `stop()` cleanly shuts down within 5 seconds from any state (running, reconnecting, backoff sleep)
- [x] `stop()` is idempotent — safe to call on an already-stopped connector
- [x] Status set to `stopped` only AFTER cleanup completes (not before)
- [x] `/api/bots/status` returns: status, failure_count, last_error, last_error_time, uptime, last_message_time, reconnect_attempts
- [x] `last_error` field is sanitized — no tokens, paths, or internal state exposed
- [x] `bot.connector.down` hook fires when connector exhausts retries (platform, error, failure_count in payload)
- [x] `bot.connector.reconnected` hook fires on recovery after failures (platform, attempts in payload)
- [x] Discord task reference is stored and properly cancelled/awaited in `stop()`
- [x] Starting an already-active connector is a no-op (no duplicate tasks, protected by lock)
- [x] State transitions enforced via `ConnectorState` StrEnum and `_set_status()` validation
- [x] All new behavior covered by unit tests (12 test cases)
- [x] No message loss on short (<5s) Telegram interruptions (offset-based replay via `start_polling`)

## Dependencies & Risks

**No external dependencies** — all changes are internal to existing files.

**Risks:**
- Discord.py internal reconnection may interact unexpectedly with `reconnect=False` — test by disconnecting briefly. The RESUME protocol should still work for Discord-initiated disconnects.
- Telegram's `start_polling()` handles network errors internally with its own retry logic. Our wrapper mainly catches startup failures and exceptions that escape the internal handler.
- Hook system has never been `fire()`d in production — these will be the first real consumers, so edge cases in the runner may surface. The `_fire_hook()` helper and non-blocking execution mitigate this.
- Fatal error detection uses exception class names (strings) to avoid importing library types. This is fragile if libraries rename exceptions — acceptable tradeoff for MVP.

## Files to Modify

| File | Changes |
|------|---------|
| `computer/parachute/connectors/base.py` | Add `ConnectorState` enum, health fields, `_stop_event`, `_task`, `_set_status()`, `_fire_hook()`, `_sanitize_error()`, `mark_failed()`, `_run_with_reconnect()`, abstract `_run_loop()`, update `status` property |
| `computer/parachute/connectors/telegram.py` | Rename `_poll()` to `_run_loop()`, fix `start()`/`stop()`, inline `_last_message_time` updates |
| `computer/parachute/connectors/discord_bot.py` | Rename `_run_client()` to `_run_loop()`, store task ref, pass `reconnect=False`, fix `start()`/`stop()` |
| `computer/parachute/api/bots.py` | Enrich `/api/bots/status`, fix `_on_connector_error` to use `mark_failed()`, guard duplicate starts under lock |
| `computer/parachute/core/hooks/events.py` | Add `BOT_CONNECTOR_DOWN`, `BOT_CONNECTOR_RECONNECTED` |
| `computer/parachute/server.py` | Add `hook_runner` to `server_ref` |
| `computer/tests/unit/test_bot_connectors.py` | Add 11 test cases for reconnection, health, lifecycle, hooks, fatal errors, state transitions |

## References

- Brainstorm: `docs/brainstorms/2026-02-16-connector-resilience-brainstorm.md`
- Issue: [#55](https://github.com/OpenParachutePBC/parachute-computer/issues/55)
- Best async lifecycle pattern in codebase: `computer/parachute/core/claude_sdk.py:80-107`
- Hook system: `computer/parachute/core/hooks/runner.py`, `events.py`
- Existing tests: `computer/tests/unit/test_bot_connectors.py`
- [AWS Architecture Blog: Exponential Backoff And Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/) — Full Jitter algorithm
- [discord.py Client.start() source](https://docs.pycord.dev/en/v2.6.1/_modules/discord/client.html) — `reconnect=False` behavior
- [python-telegram-bot: Handling network errors](https://github.com/python-telegram-bot/python-telegram-bot/wiki/Handling-network-errors) — Internal retry behavior
