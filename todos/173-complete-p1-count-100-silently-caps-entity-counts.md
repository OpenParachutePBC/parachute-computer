---
status: complete
priority: p1
issue_id: "111"
tags: [code-review, python, brain, data-integrity]
dependencies: []
---

# count=100 silently caps entity counts — incorrect data shown to users and agents

## Problem Statement
`count_entities()` and `list_schema_types_with_counts()` both use `count=100` as a parameter to `WOQLClient.query_document()`. This caps results to 100. If a type has 150 entities, the function returns 100 — a silently wrong count displayed in the sidebar. The `handle_delete_type` guard uses this count to block deletion; it works (>0 is truthy) but shows a wrong count in error messages. Callers only need an existence check (>0), not the true count.

## Findings
- knowledge_graph.py:343 (`count_entities`) — `count=100` hard cap
- knowledge_graph.py:399 (`list_schema_types_with_counts` inline lambda) — `count=100` hard cap

Python reviewer confidence 91. Performance reviewer confirms this is O(N) document fetch per type just to count. Simplicity reviewer recommends renaming to `has_entities()` with `count=1`.

## Proposed Solutions
### Option 1: Rename to has_entities() returning bool with count=1
Rename `count_entities()` to `has_entities()` returning bool, use `count=1` (O(1) existence check). Update callers to use bool. Best approach.

### Option 2: Use WOQL woql_count aggregate query
Use WOQL `woql_count` aggregate query for true counts.

### Option 3: Remove count=100 cap
Remove `count=100` cap to return true count (O(N) cost unchanged, but at least correct).

## Recommended Action
Option 1 — both callers only need a boolean check.

## Technical Details
**Affected files:**
- computer/modules/brain/knowledge_graph.py:343
- computer/modules/brain/knowledge_graph.py:399

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Entity counts never silently capped
- [ ] Delete guard correctly uses existence check
- [ ] Sidebar shows accurate counts (if counts still shown)

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
**Learnings:**
- `query_document(count=100)` fetches up to 100 full documents to perform a count — both O(N) expensive and silently wrong for types with >100 entities
- The function name `count_entities()` implies a true count but it returns a capped value; callers are misled
