---
status: complete
priority: p2
issue_id: "190"
tags: [code-review, python, brain, mcp, duplication]
dependencies: []
---

# brain_create_type and brain_update_type have diverging duplicated field input schemas

## Problem Statement
The `additionalProperties` block describing field definitions is nearly identical in both tool descriptors. `brain_update_type` is missing the "description" property on individual fields that `brain_create_type` has — so agents using `brain_update_type` get no schema hint for field description, even though the backend accepts it. Two separate copies of the schema will continue to diverge.

## Findings
- mcp_tools.py:193-217 (`brain_create_type`) — includes "description" property on fields
- mcp_tools.py:242-256 (`brain_update_type`) — missing "description" property
- Pattern Recognition reviewer confidence 88

## Proposed Solutions
### Option 1: Extract shared _FIELD_SPEC_SCHEMA constant
Extract shared `_FIELD_SPEC_SCHEMA` constant dict at module level. Reference it in both tool definitions. Add missing "description" property to ensure consistency.

## Recommended Action

## Technical Details
**Affected files:**
- computer/modules/brain/mcp_tools.py:193-217
- computer/modules/brain/mcp_tools.py:242-256

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Single field spec schema definition
- [ ] `brain_update_type` input schema includes "description" property for fields

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
