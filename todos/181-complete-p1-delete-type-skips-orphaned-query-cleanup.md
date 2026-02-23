---
status: complete
priority: p1
issue_id: "111"
tags: [code-review, python, brain, mcp, data-integrity]
dependencies: []
---

# handle_delete_type MCP tool skips orphaned saved query cleanup

## Problem Statement
The HTTP DELETE `/types/{name}` route purges saved queries that reference the deleted type (module.py:272-281). The MCP `handle_delete_type` handler does NOT perform this cleanup. Deleting a type via MCP leaves orphaned saved queries in `queries.json` referencing a non-existent type, causing confusing downstream errors when those queries are listed or applied.

## Findings
- computer/modules/brain/mcp_tools.py:596-615 — no query cleanup after delete
- computer/modules/brain/module.py:272-281 — HTTP route performs cleanup

Agent-native reviewer confidence 85.

## Proposed Solutions
### Option 1: Extract shared cleanup helper
Extract the cleanup logic into a shared `BrainModule._purge_queries_for_type(name)` helper. Call from both HTTP DELETE handler and `handle_delete_type`.

### Option 2: Duplicate cleanup in handle_delete_type
Duplicate the cleanup in `handle_delete_type` (quick fix, not recommended — logic divergence over time).

## Recommended Action
Option 1.

## Technical Details
**Affected files:**
- computer/modules/brain/mcp_tools.py:596-615
- computer/modules/brain/module.py:272-281

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Deleting a type (via HTTP or MCP) removes associated saved queries from `queries.json`
- [ ] `brain_list_saved_queries` never returns queries for deleted types

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
**Learnings:**
- HTTP route and MCP handler implement the same logical operation but diverged on cleanup — a common risk when the same action has two entry points and post-action side effects are added to only one
- Extracting shared helpers (Option 1) is the correct pattern to prevent future divergence
