---
status: complete
priority: p2
issue_id: "183"
tags: [code-review, python, flutter, brain, architecture]
dependencies: []
---

# /schemas and /types endpoints return incompatible field wire formats

## Problem Statement
Two endpoints return different field shapes. /schemas (via `_format_schemas_for_api` in module.py) returns fields as a map keyed by field name: `{"fields": {"name": {"type": "string"}}}`. /types (via `list_schema_types_with_counts` in knowledge_graph.py) returns fields as a list with name embedded: `{"fields": [{"name": "name", "type": "string"}]}`. Additionally, `_format_field_for_api` emits "values" for enum fields while `_format_schemas_for_api` emits "enum". `BrainField.fromJson` works around this with `json['values'] ?? json['enum']`.

## Findings
- knowledge_graph.py:25-69 (`_format_field_for_api`, emits "values")
- module.py:419-452 (`_format_field`, emits "enum")
- BrainField.fromJson:20-21 has the `?? json['enum']` workaround
- Architecture reviewer confidence 91, Pattern Recognition reviewer confidence 91
- Two separate formatting functions diverging is a maintenance hazard

## Proposed Solutions
### Option 1: Consolidate to one formatting function
Make /schemas delegate to the same function as /types. Use "values" key everywhere (new format). Update `BrainField.fromJson` to only check "values".

### Option 2: Formally deprecate /schemas
Route its callers to /types.

## Recommended Action
Option 1 short-term, Option 2 long-term.

## Technical Details
**Affected files:**
- computer/modules/brain/knowledge_graph.py:25-69
- computer/modules/brain/module.py:419-452
- app/lib/features/brain/models/brain_field.dart:20-21

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Both endpoints use identical field format
- [ ] No `?? json['enum']` fallback needed in `BrainField.fromJson`

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
