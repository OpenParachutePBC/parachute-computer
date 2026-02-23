---
status: complete
priority: p1
issue_id: "111"
tags: [code-review, python, brain, async, performance]
dependencies: []
---

# Blocking sync file I/O inside async FastAPI routes

## Problem Statement
All query route handlers (GET/POST/DELETE `/queries`) use `Path.read_text()` and `Path.write_text()` directly on the event loop thread inside `async def` functions. These are blocking syscalls that block the event loop.

## Findings
- computer/modules/brain/module.py:276 — `Path.read_text()` in async context
- computer/modules/brain/module.py:281 — `Path.write_text()` in async context
- computer/modules/brain/module.py:293 — `Path.read_text()` in async context
- computer/modules/brain/module.py:304 — `Path.read_text()` in async context
- computer/modules/brain/module.py:310 — `Path.write_text()` in async context
- computer/modules/brain/module.py:320 — `Path.read_text()` in async context
- computer/modules/brain/module.py:325 — `Path.write_text()` in async context
- computer/modules/brain/mcp_tools.py:625 — `Path.read_text()` in async context
- computer/modules/brain/mcp_tools.py:642 — `Path.read_text()` in async context
- computer/modules/brain/mcp_tools.py:650 — `Path.write_text()` in async context
- computer/modules/brain/mcp_tools.py:666 — `Path.read_text()` in async context
- computer/modules/brain/mcp_tools.py:671 — `Path.write_text()` in async context

Python reviewer confidence 90.

## Proposed Solutions
### Option 1: Wrap file I/O in asyncio.to_thread()
Wrap file I/O in `asyncio.to_thread()`: `await asyncio.to_thread(queries_path.read_text)`. Non-blocking, no new dependencies.

### Option 2: Use aiofiles library
Use `aiofiles` library for async file I/O.

## Recommended Action
Option 1 — no new dependencies.

## Technical Details
**Affected files:**
- computer/modules/brain/module.py:276, :281, :293, :304, :310, :320, :325
- computer/modules/brain/mcp_tools.py:625, :642, :650, :666, :671

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] `queries.json` reads and writes do not block event loop
- [ ] All file I/O in async functions runs in thread pool

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
**Learnings:**
- `Path.read_text()` / `Path.write_text()` are synchronous blocking calls; calling them directly in `async def` without `await asyncio.to_thread()` blocks the entire event loop for the duration of the syscall
- FastAPI runs on a single-threaded event loop by default; one blocking file read can stall all in-flight requests
