---
status: complete
priority: p1
issue_id: "111"
tags: [code-review, python, brain, concurrency, mcp]
dependencies: []
---

# MCP query handlers bypass _queries_lock — race condition on queries.json

## Problem Statement
HTTP routes in `module.py` use `async with _queries_lock:` for all `queries.json` access (reads + writes). MCP handlers `handle_list_saved_queries`, `handle_save_query`, `handle_delete_saved_query` in `mcp_tools.py` read/write the same file without any lock. Concurrent MCP tool call + HTTP request can corrupt `queries.json` via lost-write race.

## Findings
- computer/modules/brain/mcp_tools.py:621 (`handle_list_saved_queries`) — no lock
- computer/modules/brain/mcp_tools.py:641 (`handle_save_query`) — no lock
- computer/modules/brain/mcp_tools.py:663 (`handle_delete_saved_query`) — no lock
- computer/modules/brain/module.py:37 — defines `_queries_lock` but it is not imported by `mcp_tools.py`

Python reviewer confidence 88. Architecture reviewer confidence 85. Pattern Recognition confidence 86. Parachute conventions confidence 83.

## Proposed Solutions
### Option 1: Move _queries_lock to BrainModule as instance attribute
Move `_queries_lock` to `BrainModule` as an instance attribute (`self._queries_lock = asyncio.Lock()`). Both HTTP routes and MCP handlers access it via `module._queries_lock`.

### Option 2: Move _queries_lock to shared import location
Move `_queries_lock` to a shared module-level location that both `module.py` and `mcp_tools.py` import.

## Recommended Action
Option 1 — cleaner; lock lives with the module that owns the data.

## Technical Details
**Affected files:**
- computer/modules/brain/mcp_tools.py:621
- computer/modules/brain/mcp_tools.py:641
- computer/modules/brain/mcp_tools.py:663
- computer/modules/brain/module.py:37

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] All `queries.json` reads/writes (both HTTP and MCP paths) acquire the same lock
- [ ] No lost-write race possible

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
**Learnings:**
- Module-level `asyncio.Lock()` defined in `module.py` is not accessible to `mcp_tools.py` unless explicitly imported or passed through; the architectural separation between HTTP routes and MCP handlers created a locking blind spot
- Lost-write race: both paths read file, one writes, then second writes — first write is silently discarded
