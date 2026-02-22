---
status: pending
priority: p2
issue_id: 35
tags: [code-review, python, async, performance]
dependencies: []
---

# Blocking File I/O in Async Journal Functions

## Problem Statement

Three journal-related functions use synchronous `file.read_text()` in async context, blocking the entire FastAPI event loop. Every journal read freezes all concurrent requests until the file I/O completes.

**Why it matters:** Under load, this creates cascading delays. One slow disk read (5-50ms) blocks hundreds of concurrent requests.

## Findings

**Source:** python-reviewer agent (confidence: 98%)

**Locations:**
- `computer/parachute/mcp_server.py:793` — `search_journals()`
- `computer/parachute/mcp_server.py:852` — `list_recent_journals()`
- `computer/parachute/mcp_server.py:882` — `get_journal()`

```python
# Line 793 (search_journals)
content = journal_file.read_text(encoding="utf-8")

# Line 852 (list_recent_journals)
content = journal_file.read_text(encoding="utf-8")

# Line 882 (get_journal)
content = journal_file.read_text(encoding="utf-8")
```

**Impact:**
- Single journal read: 5-50ms blocked event loop
- 100 concurrent requests: 500ms-5s total blocking time
- FastAPI server becomes unresponsive during journal operations

## Proposed Solutions

### Option 1: asyncio.to_thread() (Recommended)
**Effort:** Small (10 minutes)
**Risk:** Low (stdlib solution)

```python
import asyncio

# In each function
content = await asyncio.to_thread(journal_file.read_text, encoding="utf-8")
```

**Pros:**
- No new dependencies
- Minimal code change
- Thread pool handles I/O concurrency

**Cons:**
- Thread pool overhead (minimal, ~0.1ms per call)

### Option 2: aiofiles Library
**Effort:** Medium (30 minutes + dependency)
**Risk:** Low (mature library)

```python
import aiofiles

async with aiofiles.open(journal_file, encoding="utf-8") as f:
    content = await f.read()
```

**Pros:**
- Native async file I/O
- Better performance for large files

**Cons:**
- New dependency (aiofiles)
- Requires updating all 3 functions

### Option 3: Pre-load Journals at Startup
**Effort:** Large (2-3 hours)
**Risk:** High (memory usage)

**Pros:**
- Zero I/O during requests

**Cons:**
- Stale data if journals updated externally
- High memory usage for large vaults

## Recommended Action

**Use `asyncio.to_thread()`** (Option 1) — simple, no dependencies, correct async pattern.

## Technical Details

**Affected files:**
- `computer/parachute/mcp_server.py` — Lines 793, 852, 882

**Affected functions:**
- `search_journals()` — Full-text search across journal files
- `list_recent_journals()` — List recent journal dates
- `get_journal()` — Get specific day's journal

**Code changes:**
```python
# Add import at top
import asyncio

# Replace all read_text() calls
content = await asyncio.to_thread(journal_file.read_text, encoding="utf-8")
```

## Acceptance Criteria

- [ ] All 3 journal functions use `asyncio.to_thread()`
- [ ] No blocking file I/O in async functions
- [ ] Performance tests show no event loop blocking
- [ ] Concurrent request handling remains responsive

## Work Log

- 2026-02-22: Identified during code review by python-reviewer agent

## Resources

- **Python docs:** https://docs.python.org/3/library/asyncio-task.html#asyncio.to_thread
- **FastAPI async:** https://fastapi.tiangolo.com/async/
- **Source PR:** feat/multi-agent-workspace-teams branch
