---
status: complete
priority: p2
issue_id: "196"
tags: [code-review, python, brain, security]
dependencies: []
---

# TerminusDB error messages leak internal schema structure and query details to API callers

## Problem Statement
`update_schema_type()` wraps TerminusDB exceptions and re-raises with `f"Schema update rejected by TerminusDB: {e}"`. module.py returns `str(e)` in HTTP 400 detail. TerminusDB errors include full WOQL queries, schema document JSON, internal graph paths, and sometimes server URLs.

## Findings
- knowledge_graph.py:564-565 — `raise ValueError(f"Schema update rejected by TerminusDB: {e}")`
- module.py:248-249 — `HTTPException(detail=str(e))`
- Security reviewer confidence 80

## Proposed Solutions
### Option 1: Log full error server-side, return sanitized message to client
Log full TerminusDB error server-side; return sanitized message to client: "Schema update rejected: field type change conflicts with existing data."

## Recommended Action

## Technical Details
**Affected files:**
- computer/modules/brain/knowledge_graph.py:564-565
- computer/modules/brain/module.py:248-249

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] API error responses do not include raw TerminusDB exception details
- [ ] Full error logged server-side for debugging

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
