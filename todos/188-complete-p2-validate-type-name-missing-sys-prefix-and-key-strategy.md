---
status: complete
priority: p2
issue_id: "188"
tags: [code-review, python, brain, security, validation]
dependencies: []
---

# _validate_type_name misses Sys* prefix; key_strategy has no allowlist validation

## Problem Statement
`_validate_type_name` blocks the exact string "Sys" but not names starting with "Sys" (like "SysUser", "SysDatabase"). TerminusDB reserves the Sys prefix. Also, the type name regex allows lowercase-first names (person, note) which are unexpected in TerminusDB. Separately, `key_strategy` is a plain `str` with no validator in `CreateSchemaTypeRequest` — any string reaches `_build_key_strategy`.

## Findings
- knowledge_graph.py:72-76 — `_RESERVED_TERMINUS_NAMES` contains "Sys" but not Sys* names
- models.py:149 — `key_strategy: str = "Random"` — no validator
- Security reviewer confidence 82/85
- `_build_key_strategy` raises `ValueError` for unknown strategies, caught and returned as 400, but defense-in-depth is missing at model layer

## Proposed Solutions
### Option 1: Strengthen validation at all three points
Add `if name.startswith("Sys"): raise ValueError(...)` to `_validate_type_name`. Add PascalCase enforcement (first char must be uppercase). Add `field_validator` on `key_strategy` with allowset `{"Lexical", "Random", "Hash", "ValueHash"}`.

## Recommended Action

## Technical Details
**Affected files:**
- computer/modules/brain/knowledge_graph.py:72-76
- computer/modules/brain/models.py:149

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Sys* type names rejected
- [ ] Lowercase-first names rejected
- [ ] Invalid `key_strategy` rejected at model validation layer

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
