---
title: "Tool as Universal Primitive"
type: feat
date: 2026-03-26
issue: 355
---

# Tool as Universal Primitive

Unify tools, agents, and MCP operations under a single `Tool` node in the graph. Separate triggers into their own table. Replace three disconnected metadata sources with one graph-native source of truth.

## Problem Statement

Agent tool metadata lives in three disconnected places: Python `TOOL_FACTORIES` (runtime), Python `AGENT_TEMPLATES` (defaults), and Flutter `_ToolDef` (UI labels). They use different names, don't validate against each other, and can't be modified without editing source code. This blocks customizability, transparency, and the Daily/Computer app split (which needs shared tool definitions with different runners).

## Acceptance Criteria

- [ ] `Tool` node table exists in graph with all ~15 existing tools seeded
- [ ] `Trigger` node table exists with schedule/event triggers seeded
- [ ] `ToolRun` node table replaces `AgentRun`
- [ ] `:CAN_CALL` edges connect agent-mode Tools to their child Tools
- [ ] `:INVOKES` edges connect Triggers to Tools
- [ ] `GET /api/daily/tools` endpoint returns Tool nodes from graph
- [ ] `GET /api/daily/triggers` endpoint returns Trigger nodes from graph
- [ ] Flutter agent UI reads tool metadata from API (no hardcoded `_ToolDef`)
- [ ] Scheduler reads from `Trigger` → `Tool` graph instead of `Agent` nodes
- [ ] `run_agent()` reads Tool + Trigger config from new schema
- [ ] Agent transcript endpoint works (uses Tool node metadata for container_slug)
- [ ] Old `Agent` and `AgentRun` tables dropped
- [ ] `process-day` and `process-note` both work end-to-end on new schema

## Overview

Four graph node types, clean separation:

| Node | Purpose | Replaces |
|------|---------|----------|
| **Tool** | What it does — query, transform, agent, mcp | Agent (config part) + TOOL_FACTORIES + Flutter _ToolDef |
| **Trigger** | When it runs — schedule, event | Agent (trigger/schedule fields) |
| **ToolRun** | What happened — observability | AgentRun |
| **Card** | Output — already exists | (unchanged) |

Key relationships:
```
(:Tool)-[:CAN_CALL]->(:Tool)
(:Trigger)-[:INVOKES]->(:Tool)
(:ToolRun)-[:CALLED]->(:Tool)
(:ToolRun)-[:PRODUCED]->(:Card)
```

## Implementation Phases

### Phase 1: Graph Schema + Seeding (Backend)

**Goal:** Tool, Trigger, and ToolRun tables exist with all builtins seeded. Old schema still runs in parallel.

#### 1a. Schema registration in `brain_chat_store.py`

Add to `ensure_schema()`:

```python
# Tool node — the universal primitive
await self.graph.ensure_node_table(
    "Tool",
    {
        "name": "STRING",            # PK: "read-days-notes", "process-day"
        "display_name": "STRING",
        "description": "STRING",
        "mode": "STRING",            # "query" | "transform" | "agent" | "mcp"
        "scope_keys": "STRING",      # JSON array: ["date"], ["entry_id"]
        "input_schema": "STRING",    # JSON schema for parameters

        # mode=query
        "query": "STRING",           # Cypher template

        # mode=transform
        "transform_prompt": "STRING",
        "transform_model": "STRING",
        "write_query": "STRING",

        # mode=agent
        "system_prompt": "STRING",
        "model": "STRING",
        "memory_mode": "STRING",     # "persistent" | "fresh"
        "trust_level": "STRING",     # "direct" | "sandboxed"
        "container_slug": "STRING",

        # mode=mcp
        "server_name": "STRING",

        # metadata
        "builtin": "STRING",         # "true" | "false"
        "enabled": "STRING",
        "template_version": "STRING",
        "user_modified": "STRING",
        "created_at": "STRING",
        "updated_at": "STRING",
    },
    primary_key="name",
)

# Trigger node — when tools run
await self.graph.ensure_node_table(
    "Trigger",
    {
        "name": "STRING",            # PK: "nightly-reflection", "on-transcription"
        "type": "STRING",            # "schedule" | "event"
        "schedule_time": "STRING",   # "4:00"
        "event": "STRING",           # "note.transcription_complete"
        "event_filter": "STRING",    # JSON
        "scope": "STRING",           # JSON: default scope
        "enabled": "STRING",
        "created_at": "STRING",
        "updated_at": "STRING",
    },
    primary_key="name",
)

# ToolRun node — replaces AgentRun
await self.graph.ensure_node_table(
    "ToolRun",
    {
        "run_id": "STRING",
        "tool_name": "STRING",
        "display_name": "STRING",
        "trigger_name": "STRING",    # or "manual"
        "status": "STRING",
        "started_at": "STRING",
        "completed_at": "STRING",
        "duration_seconds": "DOUBLE",
        "session_id": "STRING",
        "scope": "STRING",           # JSON
        "card_id": "STRING",
        "error": "STRING",
        "container_slug": "STRING",
        "date": "STRING",
        "entry_id": "STRING",
        "created_at": "STRING",
    },
    primary_key="run_id",
)

# Relationships
await self.graph.ensure_rel_table("CAN_CALL", "Tool", "Tool")
await self.graph.ensure_rel_table("INVOKES", "Trigger", "Tool")
```

#### 1b. Define TOOL_TEMPLATES and TRIGGER_TEMPLATES

In `brain_chat_store.py`, define builtin templates. These replace `AGENT_TEMPLATES`:

**Tool templates (~15 tools):**

| name | mode | scope_keys | Notes |
|------|------|-----------|-------|
| `read-days-notes` | query | ["date"] | Cypher: MATCH Notes by date |
| `read-days-chats` | query | ["date"] | Cypher: MATCH Chats active on date |
| `summarize-chat` | transform | ["date", "session_id"] | Query messages → Haiku summary |
| `read-recent-cards` | query | [] | Cypher: MATCH Cards from last N days |
| `read-recent-journals` | query | [] | Cypher: MATCH Notes from last N days |
| `read-recent-sessions` | query | [] | Cypher: MATCH Chats from last N days |
| `write-card` | query | [] | Cypher: MERGE Card |
| `read-this-note` | query | ["entry_id"] | Cypher: MATCH Note by entry_id |
| `update-this-note` | query | ["entry_id"] | Cypher: SET Note content |
| `update-note-tags` | query | ["entry_id"] | Cypher: SET Note tags |
| `update-note-metadata` | query | ["entry_id"] | Cypher: SET Note metadata field |
| `process-day` | agent | ["date"] | Daily reflection — calls child tools |
| `process-note` | transform | ["entry_id"] | Transcript cleanup |
| `search-memory` | mcp | [] | Parachute MCP: search_memory |
| `list-notes` | mcp | [] | Parachute MCP: list_notes |

**Trigger templates (2):**

| name | type | target tool | schedule/event |
|------|------|------------|---------------|
| `nightly-reflection` | schedule | process-day | 4:00 |
| `on-transcription` | event | process-note | note.transcription_complete |

#### 1c. Implement `seed_builtin_tools()` and `seed_builtin_triggers()`

Follow the same version-aware pattern as `seed_builtin_agents()`:
- Check existing by name
- Compare `template_version`
- Respect `user_modified` flag
- Auto-update unmodified tools when template version bumps
- Create `:CAN_CALL` edges for agent-mode tools
- Create `:INVOKES` edges for triggers

#### Files changed in Phase 1:
- `computer/parachute/db/brain_chat_store.py` — schema + seeding
- `computer/parachute/db/brain.py` — possibly no changes (ensure_node_table already generic)

---

### Phase 2: API Endpoints + Execution Rewire (Backend)

**Goal:** New `/tools` and `/triggers` endpoints. Scheduler and agent runner read from new schema. Old `/agents` endpoints still work as thin wrappers during transition.

#### 2a. New API endpoints in `module.py`

| Method | Route | Purpose |
|--------|-------|---------|
| GET | `/tools` | List all Tool nodes |
| GET | `/tools/templates` | Return TOOL_TEMPLATES for onboarding |
| GET | `/tools/{name}` | Get specific Tool node |
| GET | `/tools/{name}/transcript` | Get transcript (uses Tool.container_slug) |
| POST | `/tools` | Create/update Tool node |
| PUT | `/tools/{name}` | Update Tool fields |
| DELETE | `/tools/{name}` | Delete Tool node |
| GET | `/triggers` | List all Trigger nodes |
| GET | `/triggers/events` | Available trigger event types |
| POST | `/triggers` | Create Trigger + INVOKES edge |
| PUT | `/triggers/{name}` | Update Trigger |
| DELETE | `/triggers/{name}` | Delete Trigger |
| POST | `/tools/{name}/run` | Manual trigger with scope |
| GET | `/tools/{name}/runs/latest` | Most recent ToolRun |

Keep old `/agents` endpoints as thin aliases during transition — they query Tool nodes where `mode IN ('agent', 'transform')` and Trigger nodes, then reshape the response to match old DailyAgentInfo format. Remove these in Phase 4.

#### 2b. Rewire scheduler (`scheduler.py`)

Currently reads `Agent` nodes where `schedule_enabled = 'true'`. Change to:

```python
# Query Trigger → Tool graph
rows = await graph.execute_cypher(
    "MATCH (t:Trigger {type: 'schedule', enabled: 'true'})-[:INVOKES]->(tool:Tool) "
    "RETURN t, tool"
)
```

Parse `Trigger.schedule_time` for APScheduler cron. Job now passes `tool.name` + `trigger.name` + `trigger.scope` to the runner.

#### 2c. Rewire agent runner (`daily_agent.py`)

`run_agent()` currently loads `DailyAgentConfig` from Agent node. Change to load from Tool + Trigger:

```python
# Load tool config
tool_rows = await graph.execute_cypher(
    "MATCH (t:Tool {name: $name}) RETURN t", {"name": tool_name}
)

# Load callable tools
can_call_rows = await graph.execute_cypher(
    "MATCH (t:Tool {name: $name})-[:CAN_CALL]->(child:Tool) RETURN child.name AS name",
    {"name": tool_name}
)
```

Runtime state (sdk_session_id for resume, run count) derived from ToolRun:

```python
# Latest session for resume
resume_rows = await graph.execute_cypher(
    "MATCH (r:ToolRun {tool_name: $name, status: 'success'}) "
    "RETURN r.session_id AS sid ORDER BY r.started_at DESC LIMIT 1",
    {"name": tool_name}
)
```

#### 2d. Rewire event dispatch

`_dispatch_event()` in `module.py` currently queries Agent nodes with matching `trigger_event`. Change to query Trigger nodes:

```python
rows = await graph.execute_cypher(
    "MATCH (t:Trigger {type: 'event', event: $event, enabled: 'true'})-[:INVOKES]->(tool:Tool) "
    "RETURN t, tool",
    {"event": event_name}
)
```

#### 2e. ToolRun recording

Replace `_create_agent_run()` / `_complete_agent_run()` with `_create_tool_run()` / `_complete_tool_run()`. Same fields, different table name, add `trigger_name`.

#### Files changed in Phase 2:
- `computer/modules/daily/module.py` — new endpoints, event dispatch
- `computer/parachute/core/daily_agent.py` — Tool+Trigger config loading, ToolRun recording
- `computer/parachute/core/scheduler.py` — read from Trigger→Tool graph
- `computer/parachute/core/agent_tools.py` — `bind_tools()` reads scope_keys from Tool nodes
- `computer/parachute/core/daily_agent_tools.py` — factories matched by Tool.name (keep for now)
- `computer/parachute/core/triggered_agent_tools.py` — same

---

### Phase 3: Flutter UI Migration

**Goal:** Flutter reads tool metadata from API. Hardcoded `_ToolDef` removed. Agent screens show Tools with Triggers.

#### 3a. Update service layer

In `daily_api_service.dart`:
- Add `fetchTools()` → `GET /api/daily/tools`
- Add `fetchTriggers()` → `GET /api/daily/triggers`
- Add `createTool()`, `updateTool()`, `deleteTool()`
- Add `createTrigger()`, `updateTrigger()`, `deleteTrigger()`
- Deprecate `fetchAgents()`, `createAgent()`, etc.

In `computer_service.dart`:
- Add `ToolInfo` model (from Tool node)
- Add `TriggerInfo` model (from Trigger node)
- Keep `DailyAgentInfo` as a backward-compat wrapper during transition

#### 3b. Update agent management screen

`agent_management_screen.dart` becomes the "Agents" view — shows Tool nodes where `mode IN ('agent', 'transform')` with their attached Triggers. Same UI concept, different data source.

#### 3c. Replace hardcoded tool labels

`agent_edit_screen.dart` currently has:
```dart
const _scheduledTools = [
  _ToolDef('read_journal', "Today's journal", '...', Icons.today),
  // ...
];
```

Replace with: fetch Tool nodes from API, render dynamically. Tool.display_name and Tool.description come from the graph. No more name mismatches.

#### 3d. Update remaining widgets

- `agent_detail_sheet.dart` — show Tool info + attached Triggers
- `agent_trigger_card.dart` — manual run button, reads from Tool node
- `agent_log_screen.dart` — reads ToolRun instead of AgentRun
- `agent_output_header.dart` — minor: references tool_name instead of agent_name
- `journal_agent_outputs_section.dart` — query Cards by tool_name

#### Files changed in Phase 3 (11 Dart files):
- `app/lib/features/daily/journal/services/daily_api_service.dart`
- `app/lib/core/services/computer_service.dart`
- `app/lib/features/daily/journal/screens/agent_management_screen.dart`
- `app/lib/features/daily/journal/screens/agent_edit_screen.dart`
- `app/lib/features/daily/journal/screens/agent_log_screen.dart`
- `app/lib/features/daily/journal/widgets/agent_detail_sheet.dart`
- `app/lib/features/daily/journal/widgets/agent_trigger_card.dart`
- `app/lib/features/daily/journal/widgets/agent_output_header.dart`
- `app/lib/features/daily/journal/widgets/journal_agent_outputs_section.dart`
- `app/lib/features/daily/journal/providers/journal_providers.dart`
- `app/lib/features/daily/journal/models/agent_card.dart`

---

### Phase 4: Cleanup

**Goal:** Remove old schema, old endpoints, old factories.

- Drop `Agent` and `AgentRun` node tables from `ensure_schema()`
- Remove `AGENT_TEMPLATES`, `seed_builtin_agents()`
- Remove `/agents/*` endpoint aliases
- Remove `TOOL_FACTORIES` registry and factory functions (once execution moves to graph-defined tools — may be Phase 2 of a larger effort)
- Remove `_ToolDef` hardcoded lists from Flutter
- Clean up `DailyAgentConfig` dataclass — replace with `ToolConfig` that reads from Tool node

#### Files changed in Phase 4:
- `computer/parachute/db/brain_chat_store.py` — remove Agent/AgentRun schema + seeding
- `computer/modules/daily/module.py` — remove /agents endpoints
- `computer/parachute/core/daily_agent.py` — remove DailyAgentConfig, old state helpers
- `computer/parachute/core/agent_tools.py` — potentially remove TOOL_FACTORIES
- `computer/parachute/core/daily_agent_tools.py` — keep factories as execution backend initially
- `app/lib/features/daily/journal/screens/agent_edit_screen.dart` — remove _ToolDef

## Technical Considerations

### Kuzu type system
Kuzu has no subtypes or inheritance. The `mode` field is the discriminator — different modes use different columns on the same table. Unused columns are empty strings. This is the same pattern as `entity_type` on Brain_Entity, `card_type` on Card, etc.

### Runtime state derivation
`sdk_session_id`, `run_count`, `last_run_at` are no longer cached on the Tool node. They're derived from ToolRun queries:
- `run_count` = `MATCH (r:ToolRun {tool_name: $name}) RETURN count(r)`
- `last_run_at` = `MATCH (r:ToolRun {tool_name: $name}) RETURN max(r.started_at)`
- `sdk_session_id` = `MATCH (r:ToolRun {tool_name: $name, status: 'success'}) RETURN r.session_id ORDER BY r.started_at DESC LIMIT 1`

If performance becomes an issue at scale, we can add a denormalized cache on the Tool node later. For now, direct queries are fine — ToolRun nodes are small and indexed by tool_name.

### Backward compatibility during transition
Phases 1-2 keep old Agent schema working. The `/agents` endpoints become thin wrappers that read from Tool + Trigger nodes and reshape the response. This lets the Flutter app work unchanged until Phase 3. No flag day.

### Tool name normalization
Current system uses inconsistent naming: `read_days_notes` (underscore) vs `process-day` (hyphen). Standardize on **kebab-case** (`read-days-notes`) for all Tool names. The old underscore names become aliases during transition.

### Execution backends stay for now
Python factory functions (`_make_read_days_notes`, etc.) and MCP handlers (`_handle_write_card`, etc.) remain as the execution backend in Phases 1-3. Tool nodes are the metadata layer; execution still goes through existing code, matched by `Tool.name`. Moving execution to graph-defined Cypher templates is a separate future effort.

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| Breaking process-day/process-note during rewire | Phase 2 has backward-compat /agents endpoints; test both agents end-to-end before dropping old schema |
| Scheduler regression | Scheduler reload reads from Trigger nodes; test with both schedule and event triggers |
| Flutter breaking during API change | Phase 3 is after backend is stable; old endpoints stay until Flutter is updated |
| ToolRun query performance for runtime state | Monitor; add index or denormalized cache if needed |
| Name conflicts during underscore→kebab migration | Alias map in bind_tools; both forms resolve to same Tool node |

## PR Strategy

| PR | Phase | Scope | Can merge independently? |
|----|-------|-------|--------------------------|
| 1 | 1 | Schema + seeding (Tool, Trigger, ToolRun tables + builtins) | Yes — additive, nothing reads yet |
| 2 | 2a | API endpoints (/tools, /triggers) + /agents aliases | Yes — new endpoints, old ones still work |
| 3 | 2b-e | Execution rewire (scheduler, runner, event dispatch, ToolRun) | Yes — reads from new schema, writes ToolRun |
| 4 | 3 | Flutter UI migration | Yes — reads from new API |
| 5 | 4 | Cleanup (drop Agent/AgentRun, remove old code) | Yes — only after PR 4 merges |

Each PR is independently shippable. The system works at every intermediate state.
