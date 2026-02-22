---
status: pending
priority: p2
issue_id: 73
tags: [code-review, python, async, quality]
dependencies: []
---

# Blocking File I/O in Async Functions (Activity Hook)

## Problem Statement

Several async functions in `activity_hook.py` use synchronous file I/O (`Path.read_text()`, `Path.write_text()`, `open()`) which blocks the event loop. While the hook runs as a standalone process (not in the server's event loop), this is still an anti-pattern that should be fixed for correctness.

## Findings

- **Source**: python-reviewer (confidence 92)
- **Locations**:
  - `computer/parachute/hooks/activity_hook.py:174` — `transcript_path.read_text()` in `read_last_exchange()`
  - `computer/parachute/hooks/activity_hook.py:379` — `cache_path.read_text()` in `get_daily_summarizer_session()`
  - `computer/parachute/hooks/activity_hook.py:399` — `cache_path.write_text()` in `save_daily_summarizer_session()`
  - `computer/parachute/hooks/activity_hook.py:429` — `open(log_file, "a")` in `append_activity_log()`
- **Note**: The hook runs via `asyncio.run()` in its own process, so this doesn't block the server. But if the hook is ever moved in-process (e.g., to a FastAPI background task), these become real problems.

## Proposed Solutions

### Solution A: Wrap with asyncio.to_thread() (Recommended)
```python
lines = await asyncio.to_thread(lambda: transcript_path.read_text().strip().split("\n"))
```
- **Pros**: Simple, no new dependencies, correct async pattern
- **Cons**: Minor overhead from thread dispatch
- **Effort**: Small (15 min)
- **Risk**: Low

### Solution B: Use aiofiles
- **Pros**: Purpose-built async file I/O
- **Cons**: New dependency
- **Effort**: Small (20 min)
- **Risk**: Low

### Solution C: Accept as-is, document the exception
The hook is a standalone process — blocking I/O is only blocking its own event loop, which has nothing else to do.
- **Pros**: No code change needed
- **Cons**: Anti-pattern that could cause issues if code is moved
- **Effort**: None
- **Risk**: Low (current), Medium (if refactored later)

## Recommended Action

<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/hooks/activity_hook.py`
- **Note**: `read_last_exchange` is the most impactful — it reads the entire transcript

## Acceptance Criteria

- [ ] All file I/O in async functions uses non-blocking patterns (or is documented as acceptable)

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #73 review | Hook runs standalone, so practical impact is low |

## Resources

- PR: https://github.com/OpenParachutePBC/parachute-computer/pull/73
