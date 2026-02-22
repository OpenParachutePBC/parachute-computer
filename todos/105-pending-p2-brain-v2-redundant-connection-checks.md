---
status: completed
priority: p2
issue_id: 94
tags: [code-review, code-simplicity, brain-v2, python]
dependencies: []
---

# Brain v2: Redundant Connection Status Checks

## Problem Statement

`knowledge_graph.py` has duplicated connection check patterns scattered across 7 methods, violating DRY principle and adding maintenance burden.

**Why it matters:** Code duplication makes refactoring error-prone. If the connection check logic needs to change (e.g., add retry logic), it must be updated in 7 places.

## Findings

**Source:** pattern-recognition-specialist agent (confidence: 85/100)

**Affected files:**
- `computer/modules/brain_v2/knowledge_graph.py`

**Duplicated pattern:**
```python
# Appears in 7 methods
if not self._connected:
    raise RuntimeError("Not connected. Call connect() first.")
```

**Locations:**
- Line 67 (create_entity)
- Line 100 (query_entities)
- Line 137 (get_entity)
- Line 152 (update_entity)
- Line 168 (delete_entity)
- Line 185 (create_relationship)
- Line 211 (traverse_graph)

## Proposed Solutions

### Option A: Extract to _ensure_connected() Method (Recommended)
**Approach:** Replace all checks with single method call

**Implementation:**
```python
def _ensure_connected(self) -> None:
    """Raise RuntimeError if not connected to TerminusDB."""
    if not self._connected:
        raise RuntimeError("Not connected. Call connect() first.")

# Usage in all methods:
def create_entity(...):
    self._ensure_connected()
    # rest of method
```

**Pros:**
- DRY: Single source of truth
- Easy to enhance (add retry logic, logging, etc.)
- Self-documenting method name
- 7 lines → 1 line in each method

**Cons:**
- Minimal (adds one method)

**Effort:** Small (15 minutes)
**Risk:** Low

### Option B: Decorator Pattern
**Approach:** Create @require_connection decorator

**Implementation:**
```python
def require_connection(func):
    @functools.wraps(func)
    async def wrapper(self, *args, **kwargs):
        if not self._connected:
            raise RuntimeError("Not connected. Call connect() first.")
        return await func(self, *args, **kwargs)
    return wrapper

# Usage:
@require_connection
async def create_entity(...):
    # no manual check needed
```

**Pros:**
- Pythonic
- Zero boilerplate in methods
- Declarative intent

**Cons:**
- More complex (requires functools)
- Decorator overhead (minimal)
- Overkill for 7 methods

**Effort:** Medium (30 minutes)
**Risk:** Low

### Option C: Keep As-Is
**Approach:** Accept duplication for explicitness

**Pros:**
- Explicit checks visible in each method
- No indirection

**Cons:**
- Maintenance burden (7 update points)
- Violates DRY

**Effort:** None
**Risk:** None (but technical debt)

## Recommended Action

(To be filled during triage)

**Suggestion:** Option A (simple, effective, aligns with Python conventions)

## Technical Details

**Affected components:**
- All 7 public async methods in KnowledgeGraphService
- Pattern occurs at start of each method

**Refactoring safety:**
- All 7 occurrences are identical
- No variations in error message or logic
- Safe to extract to shared method

**Future enhancement:** _ensure_connected() could later add:
- Automatic reconnection on disconnect
- Connection health check
- Logging/metrics

## Acceptance Criteria

- [ ] Single _ensure_connected() method exists
- [ ] All 7 methods call _ensure_connected() at start
- [ ] Identical error message in all cases
- [ ] All tests still pass
- [ ] No behavior changes (pure refactor)

## Work Log

### 2026-02-22
- **Created:** pattern-recognition-specialist agent flagged during /para-review of PR #97
- **Note:** Classic DRY refactor, low risk, high clarity gain

## Resources

- **PR:** #97 (Brain v2 TerminusDB MVP)
- **Review agent:** pattern-recognition-specialist
- **Pattern:** Guard clause extraction
- **Similar:** code-simplicity-reviewer also flagged this (lines 180-185 reduction)
