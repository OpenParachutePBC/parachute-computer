---
status: complete
priority: p1
issue_id: "111"
tags: [code-review, python, brain, security]
dependencies: []
---

# update_schema_type() missing _validate_type_name() — reserved names can corrupt TerminusDB schema

## Problem Statement
`create_schema_type()` calls `_validate_type_name(name)` as its first action. `update_schema_type()` does not. The HTTP PUT `/types/{type_name}` route has its own regex guard, but the MCP `brain_update_type` handler calls `kg.update_schema_type()` directly without any name validation. An agent can pass reserved names like "Class", "Enum", "Sys" — potentially replacing TerminusDB system schema documents.

## Findings
- computer/modules/brain/knowledge_graph.py:521 — `update_schema_type()` has no `_validate_type_name()` call
- computer/modules/brain/module.py:239 — HTTP route has regex guard, but MCP path bypasses it

Security reviewer confidence 82.

## Proposed Solutions
### Option 1: Add _validate_type_name() to update_schema_type()
Add `self._validate_type_name(name)` as the first line of `update_schema_type()`, mirroring `create_schema_type()`.

## Recommended Action
Option 1 — trivial one-line fix mirroring the existing pattern.

## Technical Details
**Affected files:**
- computer/modules/brain/knowledge_graph.py:521
- computer/modules/brain/module.py:239

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Reserved type names rejected from `update_schema_type()` regardless of entry point

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
**Learnings:**
- `create_schema_type()` correctly validates at the service layer; `update_schema_type()` was written without the matching guard — a missed application of the same defensive pattern
- TerminusDB reserved type names (Class, Enum, Sys, etc.) appearing as user-defined types could overwrite system schema documents on `replace_document`
