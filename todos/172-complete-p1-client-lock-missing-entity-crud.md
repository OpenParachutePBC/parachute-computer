---
status: complete
priority: p1
issue_id: "111"
tags: [code-review, python, brain, concurrency, thread-safety]
dependencies: []
---

# _client_lock not held in pre-existing entity CRUD sync closures

## Problem Statement
PR #111 introduces `_client_lock` (threading.Lock) with an explicit comment "All client calls from asyncio.to_thread() must acquire this lock." The new schema CRUD methods correctly use it. But all pre-existing entity CRUD methods do NOT: `create_entity`, `query_entities`, `get_entity`, `update_entity`, `delete_entity`, `create_relationship`, `traverse_graph`. WOQLClient uses `requests.Session` which is NOT thread-safe. Concurrent agent calls to `brain_create_entity` + `brain_create_type` will race on the shared client.

## Findings
- knowledge_graph.py:190 (`_create_sync`) — no lock
- knowledge_graph.py:228 (`_query_sync`) — no lock
- knowledge_graph.py:259 (`_get_sync`) — no lock
- knowledge_graph.py:281 (`_update_sync`) — no lock
- knowledge_graph.py:310 (`_delete_sync`) — no lock
- knowledge_graph.py:617 (`_create_rel_sync`) — no lock
- knowledge_graph.py:661+ (`_traverse_woql`) — no lock

Confirmed by Python reviewer (confidence 93) and Pattern Recognition reviewer (confidence 90).

## Proposed Solutions
### Option 1: Add with self._client_lock to all existing _*_sync inner functions
Add `with self._client_lock:` wrapper to all existing `_*_sync` inner functions. Simple, consistent, low risk.

### Option 2: Replace threading.Lock with asyncio.Lock
Replace `threading.Lock` with `asyncio.Lock` and restructure all sync closures to not use threads — larger refactor.

## Recommended Action
Option 1 — minimal targeted fix.

## Technical Details
**Affected files:**
- computer/modules/brain/knowledge_graph.py:190
- computer/modules/brain/knowledge_graph.py:228
- computer/modules/brain/knowledge_graph.py:259
- computer/modules/brain/knowledge_graph.py:281
- computer/modules/brain/knowledge_graph.py:310
- computer/modules/brain/knowledge_graph.py:617
- computer/modules/brain/knowledge_graph.py:661+

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] All `_*_sync` closures that call `self.client.*` acquire `_client_lock` before calling

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
**Learnings:**
- PR #111 introduced the lock for new schema CRUD but did not retrofit it onto the pre-existing entity CRUD methods — an incomplete application of the locking strategy
- requests.Session is documented as not thread-safe; concurrent calls without a lock risk connection pool corruption
