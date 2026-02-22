---
status: completed
priority: p2
issue_id: 94
tags: [code-review, performance, brain-v2, python]
dependencies: []
---

# Brain v2: N+1 Query Pattern in BrainInterface search() Method

## Problem Statement

The `search()` method for BrainInterface compatibility performs O(N) queries where N = number of schemas, iterating through all schemas and querying each entity type separately. With 10 schemas and 100 entities each, this executes 10 separate TerminusDB queries.

**Why it matters:** This pattern doesn't scale. As users add more schemas and entities, search becomes progressively slower. Full-text search across all entity types should be a single query.

## Findings

**Source:** performance-oracle agent (confidence: 95/100)

**Affected files:**
- `computer/modules/brain_v2/module.py:207-250`

**Current implementation:**
```python
for schema in self.schemas:  # N iterations
    entity_type = schema.get("@id", "")
    response = await kg.query_entities(entity_type, limit=100)  # N queries
    for entity in response.get("results", []):
        # Substring search in Python
```

**Performance characteristics:**
- Sequential queries (not parallelized)
- N database round-trips for N entity types
- Client-side filtering (substring search after fetch)
- Early termination at 20 results doesn't prevent all queries

**Evidence:**
- With 10 schemas: 10 queries minimum
- With 100 entities/schema: fetches 1000 entities before filtering
- Query time scales linearly with schema count
- README.md Phase 2 acknowledges: "Full-text search: Search across entity content"

## Proposed Solutions

### Option A: WOQL Full-Text Query (Recommended for Phase 2)
**Approach:** Use WOQL to query across all entity types in single request

**Implementation sketch:**
```python
# Single WOQL query across all types
query = WOQLQuery().woql_and(
    WOQLQuery().triple("v:Entity", "rdf:type", f"@schema:{entity_type}"),
    # Full-text search predicate (TerminusDB supports this)
)
```

**Pros:**
- O(1) queries instead of O(N)
- Database-side filtering (faster)
- Scales to thousands of entities
- Proper solution for production

**Cons:**
- Requires WOQL full-text search implementation
- More complex than current approach
- Out of scope for Phase 1 MVP

**Effort:** Large (4-6 hours for WOQL query + testing)
**Risk:** Medium

### Option B: Parallel Queries with asyncio.gather()
**Approach:** Keep N queries but execute in parallel

**Implementation:**
```python
tasks = [
    kg.query_entities(schema["@id"], limit=100)
    for schema in self.schemas
]
results = await asyncio.gather(*tasks, return_exceptions=True)
```

**Pros:**
- Simple change (10 lines)
- Reduces latency from sum(query_times) to max(query_time)
- No WOQL complexity
- Suitable for Phase 1 MVP

**Cons:**
- Still N queries (just faster)
- Doesn't address client-side filtering
- Memory usage scales with entity count

**Effort:** Small (30 minutes)
**Risk:** Low

### Option C: Mark as Known Limitation
**Approach:** Document in README.md as Phase 1 limitation, defer to Phase 2

**Pros:**
- No code changes
- Acknowledges technical debt explicitly
- Aligns with MVP scope

**Cons:**
- Search remains slow for large datasets
- User-facing performance issue

**Effort:** Minimal (5 minutes)
**Risk:** Low (but UX impact)

## Recommended Action

(To be filled during triage)

**Suggestion:** Option B for Phase 1 (quick win), Option A for Phase 2 (proper fix)

## Technical Details

**Affected components:**
- `BrainV2Module.search()` method (BrainInterface compatibility)
- Used by chat/daily modules for entity search

**Performance impact:**
- Current: 10 schemas × 100ms/query = 1000ms total
- Option B: max(100ms) = 100ms total (10x faster)
- Option A: ~50ms for single WOQL query (20x faster)

**Phase 2 note:** README.md line 219 lists "Full-text search: Search across entity content" as planned enhancement

## Acceptance Criteria

**For Option B:**
- [ ] All schema queries execute in parallel
- [ ] Total search time < max(single_query_time) + overhead
- [ ] Exceptions from individual queries don't crash search
- [ ] Test with 10+ schemas, verify parallel execution
- [ ] Measure before/after latency

**For Option A (Phase 2):**
- [ ] Single WOQL query across all entity types
- [ ] Database-side full-text search (not substring)
- [ ] Pagination support
- [ ] <100ms for 1000 entities

## Work Log

### 2026-02-22
- **Created:** performance-oracle agent flagged during /para-review of PR #97
- **Note:** README.md already acknowledges this as Phase 2 work (full-text search)

## Resources

- **PR:** #97 (Brain v2 TerminusDB MVP)
- **Review agent:** performance-oracle
- **TerminusDB WOQL docs:** https://terminusdb.com/docs/guides/woql
- **Related:** README.md:219 (Phase 2 enhancement plan)
