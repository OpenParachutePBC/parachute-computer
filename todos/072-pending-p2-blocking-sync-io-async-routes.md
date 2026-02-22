---
status: pending
priority: p2
issue_id: 75
tags: [code-review, performance, python]
dependencies: []
---

# Blocking Synchronous File I/O in Async Route Handlers

## Problem Statement

All rewritten route handlers in `agents.py`, `hooks.py`, and `capabilities.py` are `async def` but perform synchronous filesystem operations (`read_text()`, `write_text()`, `write_bytes()`, `unlink()`) that block the event loop. FastAPI runs `async def` routes on the main event loop — sync I/O here blocks all other concurrent requests.

## Findings

- **Source**: python-reviewer (P2, confidence 90/88)
- **Location**: `api/agents.py:88,159,218,253,287`, `api/hooks.py:40`, `api/capabilities.py:51`
- **Evidence**: `async def list_agents`, `async def get_agent`, etc. all call `path.read_text()` synchronously. FastAPI convention: use `def` for sync I/O (runs in threadpool automatically) or wrap in `asyncio.to_thread()`.

## Proposed Solutions

### Solution A: Change to `def` routes where no async I/O needed (Recommended)
Routes that only do file I/O (no `await`) should be `def` — FastAPI runs them in a threadpool automatically.
- **Pros**: Simplest fix, follows FastAPI best practices
- **Cons**: Routes that also call async code need the `to_thread` approach instead
- **Effort**: Small
- **Risk**: None

### Solution B: Wrap sync I/O in `asyncio.to_thread()`
Keep `async def` but wrap file operations.
- **Pros**: Keeps consistent async signatures
- **Cons**: More verbose
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/api/agents.py`, `api/hooks.py`, `api/capabilities.py`

## Acceptance Criteria
- [ ] No synchronous file I/O on the event loop in async route handlers
- [ ] Either routes are `def` or sync I/O is wrapped in `asyncio.to_thread()`

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | FastAPI auto-threadpools `def` routes |

## Resources
- PR: #75
