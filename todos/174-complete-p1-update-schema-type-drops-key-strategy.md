---
status: complete
priority: p1
issue_id: "111"
tags: [code-review, python, brain, data-integrity]
dependencies: []
---

# update_schema_type() silently drops @key and @documentation on every update

## Problem Statement
`update_schema_type()` uses `replace_document` which is a full document replacement. The `class_doc` it constructs only has `@type`, `@id`, and the new fields — it omits `@key` and `@documentation`. Every update call silently wipes the key strategy (Random/Lexical/Hash/ValueHash) and description. A type created with Hash key strategy will get a different key strategy after any field edit, breaking IRI determinism for existing entities.

## Findings
- knowledge_graph.py:546-550 — `class_doc` missing `@key` and `@documentation`
- Compare with `create_schema_type` at :498-505 which includes both

Python reviewer confidence 92. `UpdateSchemaTypeRequest` model has no `key_strategy` or `description` fields, so there's no way to pass them through at all.

## Proposed Solutions
### Option 1: Fetch existing doc then merge
Fetch the existing class document first, extract its `@key` and `@documentation`, merge them into the replacement doc. Small extra round trip.

### Option 2: Add optional fields to UpdateSchemaTypeRequest
Add optional `key_strategy` and `description` fields to `UpdateSchemaTypeRequest`; default to fetching from existing doc if not provided.

## Recommended Action
Option 1 — simplest correct fix; callers don't need to know `@key` internals.

## Technical Details
**Affected files:**
- computer/modules/brain/knowledge_graph.py:546-550

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Updating a type's fields preserves existing `@key` strategy
- [ ] `@documentation` preserved if not explicitly changed

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
**Learnings:**
- TerminusDB `replace_document` is a full document replacement, not a merge/patch — any fields omitted from the replacement doc are permanently lost
- Hash key strategy is particularly dangerous to lose silently: existing entity IRIs were computed with it; after the key strategy changes, new entities get different IRIs and queries expecting the old pattern break
