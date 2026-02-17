# Permission Request Cleanup — Leaking Dictionaries

**Status**: Brainstorm complete, ready for planning
**Priority**: P2 (Server reliability)
**Modules**: computer

---

## What We're Building

Auto-cleanup for leaking permission dictionaries in `PermissionHandler` and `Orchestrator`. Today, `pending_permissions`, `pending` (tool approvals), and `pending_questions` (AskUserQuestion futures) accumulate entries that are never cleaned up when sessions end abnormally or futures are cancelled.

### Specific Gaps

1. **`orchestrator.pending_permissions`** (`orchestrator.py` line 197) — Maps session_id to PermissionHandler. The `finally` block (lines 1173-1178) cleans up `session.id`, but if an exception occurs before re-keying from `"pending"` to the real session ID (line 976), the `"pending"` key leaks.

2. **`PermissionHandler.pending`** (line 152) — Per-handler dict of tool approval futures. `_request_approval` deletes entries after timeout, but if the future is cancelled or the session dies before the `await` completes, the entry is orphaned.

3. **`PermissionHandler.pending_questions`** (line 155) — Per-handler dict of AskUserQuestion futures. Same orphan risk as `pending`.

4. **`cleanup_stale()` exists but is never called** (lines 613-626) — Cleans `self.pending` but not `self.pending_questions`. No caller anywhere in the codebase.

---

## Why This Approach

### The Happy Path Works, Edge Cases Don't

On normal session completion, the `finally` block removes the handler from `pending_permissions`, and individual futures clean up their dict entries after resolution or timeout. The leak happens in edge cases:

- Session crashes before ID reassignment
- Client disconnects mid-question (future is cancelled)
- Server restart while questions are pending
- Network timeout during tool approval

### Existing Infrastructure

- `cleanup_stale()` method already exists on `PermissionHandler` with the right shape (iterates pending, resolves old entries as denied)
- The `finally` block in `_run_chat_session` is the natural cleanup point
- `asyncio` event loop supports periodic background tasks via `asyncio.create_task`

---

## Key Decisions

### 1. Fix the Finally Block (Primary Cleanup)

**Decision**: Add a `cleanup()` method to `PermissionHandler` that resolves ALL pending futures with "denied" and clears both `pending` and `pending_questions` dicts. Call this from the orchestrator's `finally` block. Also handle the "pending" key case — clean up both `session.id` and the original "pending" key if they differ.

```python
# PermissionHandler.cleanup()
def cleanup(self) -> None:
    """Resolve all pending futures as denied and clear state."""
    for request_id, future in list(self.pending.items()):
        if not future.done():
            future.set_result(False)  # Deny
    self.pending.clear()

    for request_id, future in list(self.pending_questions.items()):
        if not future.done():
            future.set_result(None)  # No answer
    self.pending_questions.clear()
```

```python
# In orchestrator finally block:
handler = self.pending_permissions.pop(session.id, None)
if handler:
    handler.cleanup()
# Also clean up "pending" key if session was re-keyed
if captured_session_id and captured_session_id != session.id:
    old_handler = self.pending_permissions.pop(captured_session_id, None)
    if old_handler:
        old_handler.cleanup()
```

### 2. Extend cleanup_stale() and Wire It as Periodic Sweep (Safety Net)

**Decision**: Extend the existing `cleanup_stale()` to also cover `pending_questions`. Add a lightweight periodic background task (every 60s) that sweeps `orchestrator.pending_permissions` for handlers with no active session, and calls `cleanup_stale()` on remaining handlers.

The stale threshold should be generous (10 minutes) since question timeouts are already 5 minutes. The sweep is a safety net, not the primary mechanism.

### 3. Don't Over-Engineer the Sweep

**Decision**: The periodic sweep is a simple `asyncio.create_task` started at server startup, cancelled at shutdown. No external scheduler, no database, no metrics beyond a debug log line.

---

## Open Questions

### 1. Should cleanup() also cancel the underlying asyncio.Future?
Setting the result is enough to unblock waiters, but cancelling ensures no lingering references. **Recommendation**: Set result (not cancel) to avoid `CancelledError` propagation in the `can_use_tool` callback chain.

### 2. Should the sweep interval be configurable?
60 seconds and 10-minute stale threshold are reasonable defaults. **Recommendation**: Hardcode for now, make configurable only if needed.

---

## Files to Modify

| File | Changes |
|------|---------|
| `computer/parachute/core/permission_handler.py` | Add `cleanup()` method; extend `cleanup_stale()` to cover `pending_questions` |
| `computer/parachute/core/orchestrator.py` | Call `handler.cleanup()` in finally block; handle "pending" key edge case; add periodic sweep task |
| `computer/parachute/server.py` | Start/stop periodic sweep task on server lifecycle |

---

## Success Criteria

- No leaked entries in `pending_permissions` after session ends (verify with debug logging)
- No orphaned futures in `pending` or `pending_questions` after client disconnect
- Periodic sweep catches any stragglers within 60 seconds
- `cleanup_stale()` is actually called (currently dead code)
- No regression in normal AskUserQuestion or tool approval flows
