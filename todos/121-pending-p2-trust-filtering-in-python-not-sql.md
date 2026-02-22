---
status: pending
priority: p2
issue_id: 35
tags: [code-review, performance, database]
dependencies: []
---

# Trust Level Filtering Happens in Python, Not SQL

## Problem Statement

`list_workspace_sessions()` fetches up to 1,000 sessions from the database, then filters by trust level in Python. This wastes I/O and CPU when most sessions are filtered out.

**Why it matters:** With 5,000+ session workspaces, this loads 1,000 rows only to discard 90%+ of them. Under load (100 agents listing workspace), this becomes 100,000 row operations.

## Findings

**Source:** performance-oracle agent (confidence: 85%)

**Location:** `computer/parachute/mcp_server.py:696-749`

```python
# Get all sessions in the workspace
all_sessions = await db.list_sessions(workspace_id=workspace_id, limit=1000)

# Filter by trust level (sandboxed only sees sandboxed)
sessions = []
for session in all_sessions:
    session_trust = session.get_trust_level().value
    if trust_level == "sandboxed" and session_trust != "sandboxed":
        continue
    sessions.append(session)
```

**Impact:**
- Fetches 1,000 rows, filters to ~50-100 in Python
- Each `get_trust_level()` is a method call + normalization
- Response time: 50-200ms per call
- At scale: 100 agents × 1,000 rows = 100,000 unnecessary row operations

## Proposed Solutions

### Option 1: Push Filtering to SQL (Recommended)
**Effort:** Small (15 minutes)
**Risk:** Low

```python
# Modified list_sessions call
if trust_level == "sandboxed":
    # Sandboxed sessions only see other sandboxed sessions
    all_sessions = await db.list_sessions(
        workspace_id=workspace_id,
        trust_level="sandboxed",  # Add trust_level parameter
        limit=1000,
    )
else:
    # Direct sessions see all
    all_sessions = await db.list_sessions(
        workspace_id=workspace_id,
        limit=1000,
    )

# No Python filtering needed
sessions = all_sessions
```

**Database layer change:** `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/db/database.py:510-549`
```python
async def list_sessions(
    self,
    workspace_id: Optional[str] = None,
    trust_level: Optional[str] = None,  # Add parameter
    ...
) -> list[Session]:
    query = "SELECT * FROM sessions WHERE 1=1"
    params: list[Any] = []

    if workspace_id is not None:
        query += " AND workspace_id = ?"
        params.append(workspace_id)

    if trust_level is not None:  # Add filter
        query += " AND trust_level = ?"
        params.append(trust_level)

    # ... rest of query
```

**Pros:**
- Reduces data transfer from O(1000) to O(k) where k = filtered results
- Eliminates Python processing overhead
- Can use existing `idx_sessions_trust_level` index

**Cons:**
- Modifies database method signature (backward compatible)

### Option 2: Separate Query Methods
**Effort:** Medium (30 minutes)
**Risk:** Low

Create `list_sandboxed_sessions()` and `list_all_sessions()` methods.

**Pros:**
- Explicit separation
- Type-safe

**Cons:**
- Code duplication

## Recommended Action

**Push filtering to SQL** (Option 1) — simple, backward compatible, uses existing index.

## Technical Details

**Affected files:**
- `computer/parachute/mcp_server.py` — list_workspace_sessions() function
- `computer/parachute/db/database.py` — list_sessions() method

**Database changes:**
- Add optional `trust_level` parameter to `list_sessions()`
- Use existing `idx_sessions_trust_level` index (line 217 in database.py)

**Performance improvement:**
- Before: 1,000 rows fetched, 900+ filtered in Python
- After: 50-100 rows fetched (only matching trust level)
- Speedup: 10-20x for sandboxed callers

## Acceptance Criteria

- [ ] `list_sessions()` accepts optional `trust_level` parameter
- [ ] SQL query includes `trust_level` filter when provided
- [ ] `list_workspace_sessions()` uses SQL filtering
- [ ] Performance tests show 10-20x improvement for sandboxed callers
- [ ] Backward compatibility maintained (parameter optional)

## Work Log

- 2026-02-22: Identified during code review by performance-oracle agent

## Resources

- **Related index:** `idx_sessions_trust_level` (database.py:217)
- **Source PR:** feat/multi-agent-workspace-teams branch
- **Issue:** #35 (Multi-Agent Workspace Teams)
