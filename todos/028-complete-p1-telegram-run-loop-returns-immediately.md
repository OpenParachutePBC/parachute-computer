---
status: complete
priority: p1
issue_id: 55
tags: [code-review, python, bot-connector, resilience]
dependencies: []
---

# Telegram _run_loop Returns Immediately — Reconnection Bypassed

## Problem Statement

`TelegramConnector._run_loop()` calls `self._app.updater.start_polling(drop_pending_updates=True)` which **returns immediately** after starting the polling in a background task. The base class `_run_with_reconnect()` treats a clean return as "connection completed successfully" and exits the loop. This means:

1. The reconnection wrapper never actually monitors the polling lifecycle
2. If polling fails after starting, no reconnection attempt is made
3. The connector reports RUNNING but the reconnect loop has already exited

Additionally, `start()` calls `self._app.initialize()` and `self._app.start()` **before** `_run_with_reconnect()`, so these setup steps are not repeated on reconnection attempts — the Application object is not re-initialized between retries.

## Findings

- **Source**: python-reviewer (F6, confidence 80), performance-oracle (confidence 92), architecture-strategist (F1 confidence 92, F6 confidence 81)
- **Location**: `computer/parachute/connectors/telegram.py:101-103` (`_run_loop`), lines 93-94 (`start`)
- **Evidence**: `start_polling()` is documented as returning immediately. Discord's `_run_loop` calls `self._client.start()` which blocks until disconnection — correct behavior.

## Proposed Solutions

### Solution A: Block _run_loop with updater stop_event (Recommended)
Make `_run_loop` block until the updater actually stops by awaiting the updater's internal stop signal:
```python
async def _run_loop(self) -> None:
    await self._app.updater.start_polling(drop_pending_updates=True)
    # Block until the updater stops (via stop() or error)
    while self._app.updater.running:
        await asyncio.sleep(1)
```
- **Pros**: Minimal change, keeps existing architecture
- **Cons**: 1-second polling granularity for detecting updater death
- **Effort**: Small
- **Risk**: Low

### Solution B: Move Application setup into _run_loop
Move `initialize()`, `start()`, handler registration, and `start_polling()` all into `_run_loop()` so they're re-executed on each reconnection attempt. Add corresponding teardown.
```python
async def _run_loop(self) -> None:
    self._app = Application.builder().token(self.bot_token).build()
    # register handlers...
    await self._app.initialize()
    await self._app.start()
    await self._app.updater.start_polling(drop_pending_updates=True)
    # block until stopped...
```
- **Pros**: Full re-initialization on reconnect, matches discord pattern
- **Cons**: Larger refactor, handler registration duplication
- **Effort**: Medium
- **Risk**: Medium — must ensure proper cleanup between attempts

### Solution C: Use python-telegram-bot's run_polling (blocking)
Replace `start_polling()` with the blocking `run_polling()` variant:
```python
async def _run_loop(self) -> None:
    self._app.run_polling(drop_pending_updates=True)
```
- **Pros**: Blocks correctly, simple
- **Cons**: `run_polling()` manages its own event loop (calls `asyncio.run()`), may conflict with existing loop
- **Effort**: Small
- **Risk**: High — event loop conflict likely

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/connectors/telegram.py`
- **Affected components**: TelegramConnector lifecycle, reconnection resilience
- **Database changes**: None

## Acceptance Criteria

- [ ] `_run_loop()` blocks for the duration of active polling
- [ ] When polling fails/stops, `_run_with_reconnect()` detects it and retries
- [ ] Application is properly re-initialized between reconnection attempts
- [ ] Existing tests continue to pass
- [ ] New test: simulate polling failure → verify reconnection occurs

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from /para-review of PR feat/bot-connector-resilience | Three agents independently identified this as the top functional issue |

## Resources

- PR branch: `feat/bot-connector-resilience`
- Issue: #55
- python-telegram-bot docs: `start_polling()` vs `run_polling()`
