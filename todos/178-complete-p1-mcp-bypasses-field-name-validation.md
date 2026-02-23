---
status: complete
priority: p1
issue_id: "111"
tags: [code-review, python, brain, security, mcp]
dependencies: []
---

# MCP tool path bypasses field name validation — arbitrary field names reach TerminusDB schema

## Problem Statement
The HTTP routes validate field names via Pydantic's `_FIELD_NAME_RE` regex (`^[a-z][a-z0-9_]*$`). The MCP tool handlers (`handle_create_type`, `handle_update_type`) call `kg.create_schema_type`/`update_schema_type` directly with raw dict field names — no validation of field names at the service layer. An agent can inject field names containing `@type`, `@id`, spaces, or TerminusDB-reserved JSON-LD keywords, corrupting the schema graph.

## Findings
- computer/modules/brain/mcp_tools.py:553-615 (`handle_create_type`, `handle_update_type`) — no field name validation
- computer/modules/brain/knowledge_graph.py:485-491 — `create_schema_type` iterates fields dict keys without validating them

Security reviewer confidence 88. Parachute conventions reviewer confidence 88.

## Proposed Solutions
### Option 1: Add field name validation at service layer
Add field name validation loop at the top of `create_schema_type()` and `update_schema_type()` in `knowledge_graph.py` — enforced at service layer regardless of entry point.

### Option 2: Add validation in each MCP handler
Add validation in each MCP handler — less robust (callers can still bypass by adding new handlers).

## Recommended Action
Option 1 — fix at service layer.

## Technical Details
**Affected files:**
- computer/modules/brain/mcp_tools.py:553-615
- computer/modules/brain/knowledge_graph.py:485-491

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Field names containing `@`, spaces, or reserved prefixes rejected with clear error from service layer
- [ ] Validation applies to both HTTP and MCP paths

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
**Learnings:**
- Validation at the HTTP layer (Pydantic model) is not sufficient when there are multiple entry points (HTTP + MCP); the service layer must validate inputs from all callers
- JSON-LD reserved keywords like `@type` and `@id` as field names would create malformed schema documents that TerminusDB may accept but interpret incorrectly
