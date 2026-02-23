---
status: complete
priority: p2
issue_id: "189"
tags: [code-review, python, brain, duplication]
dependencies: []
---

# Field compilation loop duplicated between create_schema_type and update_schema_type

## Problem Statement
The 12-line field compilation loop (initialize enum_docs and compiled_fields, iterate fields, validate, compile each field) is copied verbatim in both `create_schema_type` and `update_schema_type`. Any future change to field validation must be applied in both places.

## Findings
- knowledge_graph.py:481-492 (`create_schema_type`) and :533-544 (`update_schema_type`) — identical 12-line blocks
- Pattern Recognition reviewer confidence 92

## Proposed Solutions
### Option 1: Extract to private helper
Extract to private helper `_compile_fields(name, fields) -> tuple[dict, list]` returning `(compiled_fields, enum_docs)`. Call from both methods.

## Recommended Action

## Technical Details
**Affected files:**
- computer/modules/brain/knowledge_graph.py:481-492
- computer/modules/brain/knowledge_graph.py:533-544

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Single field compilation implementation
- [ ] No duplication between create and update paths

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
