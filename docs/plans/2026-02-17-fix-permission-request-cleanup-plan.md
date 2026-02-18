---
title: "fix: Permission request cleanup — prevent leaked pending state"
type: fix
date: 2026-02-17
issue: 54
priority: P2
modules: computer
---

# fix: Permission request cleanup — prevent leaked pending state

## Enhancement Summary

**Deepened on:** 2026-02-17
**Agents used:** python-reviewer, security-sentinel, performance-oracle, architecture-strategist, code-simplicity-reviewer, parachute-conventions-reviewer, pattern-recognition-specialist, best-practices-researcher

### Key Improvements from Deepening
1. **Dropped Phase 3 (periodic sweep)** — 5/7 agents agreed it's YAGNI; if Phase 1+2 work correctly, no sweep is needed. Avoids introducing a new background task pattern that violates existing conventions.
2. **Fixed `datetime.utcnow()` deprecation** — Replaced with `datetime.now(timezone.utc)` per Python 3.12+ requirements.
3. **Added `_future` field to dataclasses** — Typed attribute instead of `getattr()` hack for proper type safety.
4. **Simplified finally block** — Use `.pop()` consistently (matches existing BotConnector pattern).
5. **Added server shutdown cleanup** — Iterate and cleanup all remaining handlers before exit.

### New Considerations Discovered
- **Security (fail-closed):** `set_result("denied")` is the correct default — never auto-grant on cleanup.
- **InvalidStateError catch IS needed:** Handles real TOCTOU race between `future.done()` check and `set_result()`.
- **Concurrent "pending" key collision** is a pre-existing bug, out of scope but documented as known limitation.
- **Performance is a non-issue:** At <50 sessions with <5 pending requests each, all operations are sub-microsecond.

---

## Overview

Fix memory leaks in `PermissionHandler` and `Orchestrator` where `pending`, `pending_questions`, and `pending_permissions` dictionaries accumulate entries that are never cleaned up on abnormal session termination, client disconnect, or server shutdown.

## Problem Statement

Three dictionaries leak entries under edge-case conditions:

1. **`orchestrator.pending_permissions`** — Maps session_id to PermissionHandler. The `finally` block (line 1211) deletes by `session.id`, but if concurrent new sessions collide on the `"pending"` key, or the session ID re-keying diverges, handlers leak permanently.

2. **`PermissionHandler.pending`** — Tool approval futures. `_request_approval` (line 521) deletes the entry after resolution, but has no `try/finally` — a `CancelledError` or other exception skips the deletion.

3. **`PermissionHandler.pending_questions`** — AskUserQuestion futures. Same pattern, same leak.

4. **`cleanup_stale()` exists (line 613) but is dead code** — never called, and only covers `pending`, not `pending_questions`.

5. **Server shutdown** — No cleanup of pending futures in the lifespan shutdown path.

## Proposed Solution

Two layers of defense (simplified from original three-layer proposal):

1. **Harden individual methods** — Add `try/finally` to `_request_approval` and `_handle_ask_user_question` so they always clean up their dict entries, even on cancellation. This is the primary mechanism.

2. **Add `cleanup()` method + fix the finally block** — New method on `PermissionHandler` that force-resolves all pending futures and clears both dicts. Called from the orchestrator's `finally` block with defensive key cleanup, and during server shutdown.

### Research Insight: Why No Periodic Sweep

The original brainstorm proposed a periodic background sweep as Phase 3. After review by 7 specialized agents, this was dropped:

- **Architecture:** Orchestrator is currently a passive component with no lifecycle methods. Adding `start()/stop()` introduces a new pattern inconsistent with the codebase.
- **Conventions:** Background jobs use APScheduler in `scheduler.py`. A raw `asyncio.create_task` diverges from this established pattern.
- **Simplicity:** If Phase 1 (`try/finally`) and Phase 2 (`cleanup()` in finally block) work correctly, leaked entries are impossible. A sweep only masks bugs in the primary cleanup.
- **YAGNI:** The `cleanup_stale()` method will be extended and kept available for manual invocation or future integration, but won't be wired to a background task.

## Technical Approach

### Phase 1: Harden `_request_approval` and `_handle_ask_user_question`

**File: `computer/parachute/core/permission_handler.py`**

#### 1a. Add `_future` field to dataclasses

Store the future reference directly on the request for type-safe access:

```python
@dataclass
class PermissionRequest:
    # ... existing fields ...
    _future: asyncio.Future[str] | None = field(default=None, repr=False)

@dataclass
class UserQuestionRequest:
    # ... existing fields ...
    _future: asyncio.Future | None = field(default=None, repr=False)
```

Then in `_request_approval` and `_handle_ask_user_question`, store the future on the request:

```python
request._future = future
```

### Research Insight: Why typed field, not getattr()

The Python reviewer flagged `getattr(request, '_future', None)` as a code smell — it implies the attribute may not exist. Using a typed dataclass field with `field(default=None)` gives proper type safety and eliminates the need for defensive `getattr()`. Direct attribute access (`request._future`) is also ~3x faster, though at this scale performance is irrelevant.

#### 1b. Fix `_request_approval` (lines 513-521)

Current code has no protection against exceptions during the await:

```python
# CURRENT (leaks on CancelledError):
decision = await asyncio.wait_for(future, timeout=self.timeout_seconds)
# ... handle decision ...
del self.pending[request_id]
```

Fix with `try/finally` and defensive deletion:

```python
# FIXED:
try:
    try:
        decision = await asyncio.wait_for(future, timeout=self.timeout_seconds)
    except asyncio.TimeoutError:
        decision = "timeout"
    # ... handle decision (existing logic) ...
finally:
    self.pending.pop(request_id, None)
    # Note: CancelledError propagates after cleanup, which is correct behavior
```

#### 1c. Fix `_handle_ask_user_question` (lines 736-747)

Same pattern — wrap the await and deletion in `try/finally`:

```python
# FIXED:
try:
    try:
        answers = await asyncio.wait_for(future, timeout=self.question_timeout_seconds)
    except asyncio.TimeoutError:
        answers = None
    # ... handle answers (existing logic) ...
finally:
    self.pending_questions.pop(request_id, None)
```

**Key detail:** Use `.pop(key, None)` instead of `del` everywhere for idempotent deletion. This matches the existing BotConnector pattern (`base.py:310`) and prevents `KeyError` if cleanup already removed the entry.

### Research Insight: Pattern Consistency

The pattern reviewer found three dict cleanup styles in the codebase:
1. `if key in dict: del dict[key]` (orchestrator.py — verbose)
2. `dict.pop(key, None)` (connectors/base.py — safe, idempotent)
3. `del dict[key]` (permission_handler.py — unsafe)

This fix standardizes on `.pop(key, None)` — the safest existing pattern.

#### 1d. Fix `datetime.utcnow()` deprecation

Replace all `datetime.utcnow()` calls with `datetime.now(timezone.utc)`:

```python
from datetime import datetime, timezone

# In PermissionRequest dataclass (line 71):
timestamp: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

# In UserQuestionRequest dataclass (line 94):
timestamp: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

# In cleanup_stale() (line 615):
now = datetime.now(timezone.utc)
```

### Research Insight: Python 3.12+ Compatibility

`datetime.utcnow()` is deprecated since Python 3.12 and will be removed in a future version. It returns a naive datetime that can cause bugs when compared with timezone-aware datetimes. `datetime.now(timezone.utc)` returns a proper timezone-aware datetime.

### Phase 2: Add `cleanup()` method and fix the finally block

**File: `computer/parachute/core/permission_handler.py`**

#### 2a. New `cleanup()` method

```python
def cleanup(self) -> None:
    """Force-resolve all pending futures and clear state. Called on session end."""
    cleaned_approvals = 0
    cleaned_questions = 0

    for request_id, request in list(self.pending.items()):
        if request._future and not request._future.done():
            try:
                request._future.set_result("denied")
            except asyncio.InvalidStateError:
                pass  # Future cancelled by asyncio between done() check and set_result()
            cleaned_approvals += 1
    self.pending.clear()

    for request_id, request in list(self.pending_questions.items()):
        if request._future and not request._future.done():
            try:
                request._future.set_result(None)
            except asyncio.InvalidStateError:
                pass
            cleaned_questions += 1
    self.pending_questions.clear()

    if cleaned_approvals or cleaned_questions:
        logger.warning(
            "Cleaned up %d pending approvals and %d pending questions for session %s",
            cleaned_approvals, cleaned_questions, self.session.id
        )
```

### Research Insight: Why `set_result("denied")`, not `cancel()`

The security reviewer confirmed `"denied"` is the safe default (fail-closed):
- `"granted:*"` would be a **critical vulnerability** (auto-approves everything on cleanup)
- `cancel()` raises `CancelledError` which could crash the `can_use_tool` callback chain
- `"denied"` is semantically correct — if the session is dead, deny all pending requests

The `InvalidStateError` catch handles a real TOCTOU race: asyncio can cancel a future between the `done()` check and `set_result()` call. This is not unreachable code — it's a genuine concurrency edge case in the single-threaded event loop (cancellation propagates during `await` suspension points).

### Research Insight: Performance at Scale

The performance reviewer confirmed all cleanup operations are negligible at expected scale (<50 sessions, <5 requests each):
- `list(dict.items())` copy: ~4.8KB for 100 entries
- `set_result()` per future: ~50ns, doesn't block the event loop
- Empty-dict iteration in `cleanup()` for normal sessions: <1 microsecond

No batching or optimization needed.

#### 2b. Extend `cleanup_stale()` (lines 613-626)

Extend the existing dead code to cover both dicts and resolve futures before deleting:

```python
def cleanup_stale(self, max_age_seconds: int = 600) -> int:
    """Clean up stale permission requests. Resolves futures before removing."""
    now = datetime.now(timezone.utc)
    cleaned = 0

    for request_id, request in list(self.pending.items()):
        age = (now - request.timestamp).total_seconds()
        if age > max_age_seconds:
            if request._future and not request._future.done():
                try:
                    request._future.set_result("denied")
                except asyncio.InvalidStateError:
                    pass
            self.pending.pop(request_id, None)
            cleaned += 1

    for request_id, request in list(self.pending_questions.items()):
        age = (now - request.timestamp).total_seconds()
        if age > max_age_seconds:
            if request._future and not request._future.done():
                try:
                    request._future.set_result(None)
                except asyncio.InvalidStateError:
                    pass
            self.pending_questions.pop(request_id, None)
            cleaned += 1

    return cleaned
```

**Key changes from current dead code:**
- Covers `pending_questions` (not just `pending`)
- Resolves futures before deleting (prevents `KeyError` in `_request_approval`)
- Default threshold raised to 600s (10 minutes) — generous safety net
- Uses `datetime.now(timezone.utc)` instead of deprecated `datetime.utcnow()`
- Only deletes by age (removes `status != "pending"` check — Phase 1's `try/finally` handles resolved entries)

**Note:** `cleanup_stale()` is kept as a public method for manual invocation or future integration, but is NOT wired to a background task (see "Why No Periodic Sweep" above).

**File: `computer/parachute/core/orchestrator.py`**

#### 2c. Fix the finally block (lines 1205-1212)

```python
finally:
    # Clean up active streams
    if stream_session_id:
        self.active_streams.pop(stream_session_id, None)
        self.active_stream_queues.pop(stream_session_id, None)

    # Clean up permission handler — try both possible keys defensively
    handler = self.pending_permissions.pop(session.id, None)
    if captured_session_id and captured_session_id != session.id:
        alt_handler = self.pending_permissions.pop(captured_session_id, None)
        if alt_handler and not handler:
            handler = alt_handler
        elif alt_handler and alt_handler is not handler:
            alt_handler.cleanup()
    if handler:
        handler.cleanup()
```

### Research Insight: Why Both Keys

The SpecFlow analyzer traced all session ID flows and confirmed the dual-key cleanup is needed as a defensive measure. While `session.id` *should* always track the finalized ID after re-keying (line 981), edge cases exist:
- Exception between re-keying (line 994) and session object update
- `finalize_session()` raises after `pending_permissions` is re-keyed

The `.pop()` pattern makes this zero-cost when keys don't exist.

### Research Insight: Also fix `active_streams` cleanup

The pattern reviewer noted the existing `active_streams` and `active_stream_queues` cleanup also uses the verbose `if x in dict: del dict[x]` pattern. While we're here, switch to `.pop()` for consistency.

**File: `computer/parachute/server.py`**

#### 2d. Add server shutdown cleanup

In the shutdown section of the lifespan manager (before setting orchestrator to None):

```python
# Clean up any remaining pending permissions before shutdown
if app.state.orchestrator:
    for session_id, handler in list(app.state.orchestrator.pending_permissions.items()):
        try:
            handler.cleanup()
        except Exception as e:
            logger.warning("Error cleaning permissions for %s during shutdown: %s", session_id, e)
    app.state.orchestrator.pending_permissions.clear()
```

### Research Insight: Shutdown Ordering

The best-practices researcher confirmed resources should shut down in reverse order of initialization. The current shutdown order (bots -> scheduler -> database) is correct. Permission cleanup should go before database close since handlers reference session objects.

## Acceptance Criteria

### Functional Requirements

- [x] `_request_approval` cleans up `self.pending` entry even on `CancelledError` (`permission_handler.py`)
- [x] `_handle_ask_user_question` cleans up `self.pending_questions` entry even on `CancelledError` (`permission_handler.py`)
- [x] `cleanup()` method resolves all pending futures and clears both dicts (`permission_handler.py`)
- [x] `cleanup()` handles `InvalidStateError` for already-cancelled futures (`permission_handler.py`)
- [x] `cleanup_stale()` covers both `pending` and `pending_questions` (`permission_handler.py`)
- [x] `cleanup_stale()` resolves futures before deleting entries (`permission_handler.py`)
- [x] Finally block cleans up both `session.id` and `captured_session_id` keys (`orchestrator.py`)
- [x] Finally block calls `handler.cleanup()` on removed handlers (`orchestrator.py`)
- [x] Server shutdown calls `cleanup()` on all remaining handlers (`server.py`)
- [x] `datetime.utcnow()` replaced with `datetime.now(timezone.utc)` (`permission_handler.py`)
- [x] `_future` field added to `PermissionRequest` and `UserQuestionRequest` dataclasses (`permission_handler.py`)
- [x] All `del dict[key]` replaced with `dict.pop(key, None)` in modified code paths

### Non-Functional Requirements

- [x] No regression in normal grant/deny/timeout flows
- [x] No regression in AskUserQuestion answer flow
- [x] `cleanup()` logging at WARNING level (indicates abnormal termination — non-zero cleanups only)

## Dependencies & Risks

**Risk: Future access from `cleanup()`** — Mitigated by adding `_future` field to dataclasses. The field is `None` by default and set in `_request_approval` / `_handle_ask_user_question`, so existing code paths are unaffected.

**Risk: Race between answer endpoint and cleanup** — The `/chat/{session_id}/answer` endpoint polls for the handler. If cleanup removes the handler mid-poll, the endpoint returns 404. This is acceptable behavior (session is gone), but worth noting.

**Risk: Concurrent "pending" key collision** — Two new sessions can overwrite each other's handler at the `"pending"` key. The cleanup fixes prevent permanent leaks (the finally block will clean up the surviving handler), but the overwritten handler is still unreachable for grant/deny. This is a pre-existing issue and out of scope for this fix — noted as a known limitation. A proper fix would use a unique temporary key (e.g., `f"pending-{uuid4().hex[:8]}"`) instead of the literal `"pending"`.

**Security consideration:** The `"denied"` default for cleanup is fail-closed by design. An attacker cannot exploit the cleanup window to get permissions auto-granted. The worst case is a legitimate grant being incorrectly denied during cleanup, which is a UX issue (user can retry), not a security vulnerability.

## Files to Modify

| File | Changes |
|------|---------|
| `computer/parachute/core/permission_handler.py` | Add `_future` field to dataclasses; fix `datetime.utcnow()`; `try/finally` in `_request_approval` and `_handle_ask_user_question`; new `cleanup()` method; extend `cleanup_stale()` |
| `computer/parachute/core/orchestrator.py` | Fix finally block: use `.pop()`, clean both session ID keys, call `handler.cleanup()` |
| `computer/parachute/server.py` | Add permission handler cleanup to shutdown sequence |

## References

- Issue: #54
- Brainstorm: `docs/brainstorms/2026-02-16-permission-request-cleanup-brainstorm.md`
- Permission handler: `computer/parachute/core/permission_handler.py`
- Orchestrator: `computer/parachute/core/orchestrator.py`
- Server lifespan: `computer/parachute/server.py`
- Chat API (answer endpoint): `computer/parachute/api/chat.py:197-262`
- Python datetime deprecation: https://blog.miguelgrinberg.com/post/it-s-time-for-a-change-datetime-utcnow-is-now-deprecated
- asyncio Future best practices: https://docs.python.org/3.11/library/asyncio-future.html
