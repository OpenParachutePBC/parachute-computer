---
status: complete
priority: p2
issue_id: "187"
tags: [code-review, python, flutter, brain, mcp, agent-native]
dependencies: []
---

# brain_query_entities only supports equality filters but UI and brain_save_query support neq/contains

## Problem Statement
The UI filter bar supports eq, neq, and contains operators (applied client-side). `brain_save_query` MCP tool stores structured filter conditions with an operator field. `brain_query_entities` passes filters directly as a TerminusDB document template (equality-only). Agents cannot replicate saved queries with neq/contains — the call succeeds but returns different results than the UI shows. No error is surfaced.

## Findings
- brain_entity_list_screen.dart:86-91 — UI supports 3 operators (eq, neq, contains)
- mcp_tools.py:48-51 — `brain_query_entities` filters described as "key-value pairs"
- knowledge_graph.py:229-231 — `template.update(filters)` — equality only
- Agent-native reviewer confidence 92

## Proposed Solutions
### Option 1: Extend brain_query_entities with structured filters
Accept structured filter list `[{field_name, operator, value}]` matching `brain_save_query` format. Implement server-side operator translation for eq/neq/contains.

### Option 2: Update description as immediate mitigation
Update `brain_query_entities` description to explicitly state "equality-only; neq and contains not supported" to prevent silent wrong results.

## Recommended Action
Option 1 long-term, Option 2 as immediate mitigation.

## Technical Details
**Affected files:**
- app/lib/features/brain/screens/brain_entity_list_screen.dart:86-91
- computer/modules/brain/mcp_tools.py:48-51
- computer/modules/brain/knowledge_graph.py:229-231

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] `brain_query_entities` description clearly documents operator support
- [ ] Ideally supports same operators as UI
- [ ] No silent result divergence between agent and UI filter application

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
