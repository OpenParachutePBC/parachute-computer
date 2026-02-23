---
status: pending
priority: p3
issue_id: "204"
tags: [code-review, python, brain, mcp, agent-native]
dependencies: []
---

# brain_query_entities filters description is ambiguous — agents will pass wrong shapes

## Problem Statement
The `brain_query_entities` MCP tool describes its `filters` parameter as "Optional field filters as key-value pairs" (mcp_tools.py:48-51). However, `brain_save_query` stores structured filter objects with shape `[{field_name, operator, value}]`. An agent that reads a saved query and tries to pass those structured filters directly to `brain_query_entities` will construct a malformed filter and receive unexpected results or errors. The description must explicitly state the flat key-value equality-only semantics and distinguish itself from the structured filter format used by `brain_save_query`.

## Findings
- `mcp_tools.py:48-51` — `brain_query_entities` filters description: "Optional field filters as key-value pairs"
- `brain_save_query` uses structured `[{field_name, operator, value}]` filter objects
- The two formats are incompatible; no cross-tool guidance is provided
- Agent-native reviewer confidence: 83

## Proposed Solutions
### Option 1: Update the description
Change the filters description to:

> "Optional equality filters as a flat key-value map (e.g., {\"status\": \"active\"}). Only supports exact match. This format differs from the structured filter list used by brain_save_query."

## Recommended Action

## Technical Details
**Affected files:**
- computer/modules/brain/mcp_tools.py:48-51

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] `brain_query_entities` filters description explicitly states equality-only semantics
- [ ] Description references the flat key-value format with an example
- [ ] Description notes the distinction from `brain_save_query`'s structured filter format

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
