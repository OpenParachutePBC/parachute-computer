---
status: complete
priority: p1
issue_id: "111"
tags: [code-review, python, brain, performance, concurrency]
dependencies: []
---

# asyncio.gather() + threading.Lock causes pool starvation in list_schema_types_with_counts

## Problem Statement
`list_schema_types_with_counts()` fires up to 20 concurrent `asyncio.to_thread()` calls via `asyncio.gather()`, each immediately blocking on `self._client_lock` (threading.Lock). Only one thread holds the lock at a time, so all concurrent threads queue serially behind it. This defeats the parallelism entirely and causes ThreadPoolExecutor pool starvation (default pool is ~12 threads on Mac; with 20 types, 8 tasks can't even start). Under concurrent HTTP requests, this creates a true deadlock where a thread holding the lock may wait for the event loop which is waiting for threads that can't progress.

## Findings
knowledge_graph.py:394-408 — asyncio.gather spawns N threads, each acquires _client_lock serially. Comment at line 352 incorrectly claims "O(1) parallel latency". Performance reviewer confirmed at confidence 92. Python reviewer confirmed at confidence 96.

## Proposed Solutions
### Option 1: Move all N count queries into a single asyncio.to_thread() call
Move all N count queries into a single `asyncio.to_thread()` call with sequential WOQL count queries — one lock acquisition, O(N) sequential lightweight queries, no gather overhead.

### Option 2: Use a WOQL aggregate count query
Use `WOQLQuery().woql_count` that counts all types in one round trip. Best approach long-term.

### Option 3: Semaphore-limited concurrency
Keep `gather()` but limit concurrency via `asyncio.Semaphore` to prevent pool starvation.

## Recommended Action
(Leave blank - to be filled during triage)

## Technical Details
**Affected files:**
- computer/modules/brain/knowledge_graph.py:394-408

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] No concurrent lock contention in count queries
- [ ] Entity counts correct
- [ ] No thread pool starvation under concurrent requests

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
**Learnings:**
- asyncio.gather() + threading.Lock is an anti-pattern: threads block immediately, serializing all work while still consuming thread pool slots
- Default ThreadPoolExecutor on Mac has ~12 threads; 20 concurrent to_thread() calls exceed this, causing starvation
