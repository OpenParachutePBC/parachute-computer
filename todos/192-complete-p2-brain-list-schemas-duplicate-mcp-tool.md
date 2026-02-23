---
status: complete
priority: p2
issue_id: "192"
tags: [code-review, python, brain, mcp, simplicity]
dependencies: []
---

# brain_list_schemas MCP tool is superseded by brain_list_types — remove to avoid agent confusion

## Problem Statement
Both `brain_list_schemas` and `brain_list_types` list schema types but return different formats (stale in-memory vs live with counts). `brain_list_types` description says "Preferred over brain_list_schemas for newer workflows" — but both remain in `BRAIN_TOOLS`. Agents presented with both will sometimes call the wrong one. The `_format_field` formatter functions are also divergent (finding 183).

## Findings
- mcp_tools.py:167-182 (`brain_list_schemas`)
- mcp_tools.py:537-550 (`brain_list_types`)
- knowledge_graph.py:319-335 (`list_schemas()` — becomes dead code after removal)
- Simplicity reviewer confidence 95, Agent-native reviewer, Parachute conventions reviewer confidence 80

## Proposed Solutions
### Option 1: Remove brain_list_schemas entirely
Remove `brain_list_schemas` from `BRAIN_TOOLS`, remove `handle_list_schemas`, remove its `TOOL_HANDLERS` entry. Remove `KnowledgeGraphService.list_schemas()` method. ~42 LOC reduction.

### Option 2: Mark as deprecated in description
Keep both but mark `brain_list_schemas` as "[DEPRECATED — use brain_list_types]" in description.

## Recommended Action
Option 1.

## Technical Details
**Affected files:**
- computer/modules/brain/mcp_tools.py:167-182
- computer/modules/brain/mcp_tools.py:537-550
- computer/modules/brain/knowledge_graph.py:319-335

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Only one schema listing tool
- [ ] `brain_list_schemas` removed
- [ ] No dead `handle_list_schemas` code

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
