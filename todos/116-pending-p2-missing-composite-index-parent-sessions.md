---
status: pending
priority: p2
issue_id: 35
tags: [code-review, performance, database]
dependencies: []
---

# Missing Composite Index on (parent_session_id, archived)

## Problem Statement

The spawn limit and rate limiting checks query sessions by `parent_session_id` with an `archived = 0` filter, but the current index only covers `parent_session_id`. This forces a table scan to filter archived status, degrading performance under load.

**Why it matters:** Each `create_session()` call runs two queries that scan parent's children. With 100 concurrent agents spawning children, this becomes 200+ row scans per second.

## Findings

**Source:** performance-oracle agent (confidence: 92%)

**Current implementation:** `computer/parachute/db/database.py:809-837`
```python
async def count_children(self, parent_session_id: str) -> int:
    async with self.connection.execute(
        """
        SELECT COUNT(*) FROM sessions
        WHERE parent_session_id = ? AND archived = 0
        """,
        (parent_session_id,),
    ) as cursor:
```

**Index exists:** Line 379 creates `idx_sessions_parent_session` on `parent_session_id` only.

**Problem:** The `archived = 0` filter happens after index seek, requiring a scan of all parent's children (typically 1-10 rows, but could be 100+ if no cleanup).

**Impact at scale:**
- 1,000 concurrent spawns = 2,000 queries scanning 10-100 rows each
- Response time: 5-50ms (single parent) → 500ms+ (contested parent)

## Proposed Solutions

### Option 1: Add Composite Index (Recommended)
**Effort:** Small (5 minutes)
**Risk:** Low (additive change)

```sql
-- In migration v18
CREATE INDEX idx_sessions_parent_active ON sessions(parent_session_id, archived)
```

**Pros:**
- O(log n) seek + O(k) where k = active children (≤10)
- Zero code changes required
- SQLite query planner will use this automatically

**Cons:**
- Slightly larger database file (minimal, ~few KB per 1000 sessions)

### Option 2: Denormalize Active Child Count
**Effort:** Medium (1 hour)
**Risk:** Medium (requires trigger maintenance)

Add `active_child_count` column to sessions, maintain via triggers.

**Pros:**
- O(1) lookup for spawn limit check

**Cons:**
- Triggers add complexity
- Risk of count drift if triggers fail

### Option 3: Cache in Redis
**Effort:** Large (2-3 hours)
**Risk:** High (new dependency)

**Pros:**
- Scales beyond SQLite limitations

**Cons:**
- Overkill for current scale
- Adds Redis dependency

## Recommended Action

**Add composite index** (Option 1) in next database migration.

## Technical Details

**Affected files:**
- `computer/parachute/db/database.py` — Add migration v18 with composite index

**Affected components:**
- Rate limiting checks (`get_last_child_created`)
- Spawn limit checks (`count_children`)

**Database changes:**
```sql
-- Migration v18
CREATE INDEX IF NOT EXISTS idx_sessions_parent_active ON sessions(parent_session_id, archived);
```

## Acceptance Criteria

- [ ] Migration v18 created with composite index
- [ ] Migration runs successfully on existing databases
- [ ] Query plan uses new index (verify with `EXPLAIN QUERY PLAN`)
- [ ] Performance tests show 10-50x improvement on contested parents

## Work Log

- 2026-02-22: Identified during code review by performance-oracle agent

## Resources

- **Source PR:** feat/multi-agent-workspace-teams branch
- **Related issue:** #35 (Multi-Agent Workspace Teams)
- **SQLite documentation:** https://www.sqlite.org/queryplanner.html#covidx
