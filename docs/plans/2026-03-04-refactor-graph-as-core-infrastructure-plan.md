---
title: "Graph as Core Infrastructure"
type: refactor
date: 2026-03-04
issue: 187
---

# Graph as Core Infrastructure

Dissolve the Brain module's ownership of the Kuzu graph. The graph becomes core server infrastructure. Brain_Entity and Brain_Relationship tables are dropped. Chat and Daily own their schema segments. A new `/api/graph/` router exposes structured MCP query tools so agents can inspect and query the graph without writing Cypher.

## Acceptance Criteria

- [ ] `Brain_Entity` and `Brain_Relationship` tables are no longer created or used
- [ ] `BrainInterface` is removed from the interface registry
- [ ] Chat and Daily modules have no `BrainInterface` dependency
- [ ] `add_episode`, `upsert_entity`, `search`, `recall` are removed from the codebase
- [ ] Brain module either: (a) becomes a thin shell providing only graph query routes, or (b) is removed entirely
- [ ] New `/api/graph/` core router exists with schema + per-table query endpoints
- [ ] New MCP tools replace the 3 legacy brain tools: `get_graph_schema` + per-table tools
- [ ] Server starts cleanly with no brain module or with the thinned-down shell
- [ ] App: Brain tab queries the new graph router (not BrainEntity model)
- [ ] App: Vault tab removed from bottom nav

## Context

### What exists today

| Component | File | Role |
|-----------|------|------|
| `BrainModule` | `modules/brain/module.py` (530 lines) | Owns Brain_Entity/Relationship tables, publishes BrainInterface, 20 MCP tools, REST API |
| `BrainInterface` | `parachute/core/interfaces.py` | Registry slot: upsert_entity, search, recall, add_episode |
| Chat module | `modules/chat/module.py` | `requires: BrainInterface` in manifest, has `_get_brain()` |
| Daily module | `modules/daily/module.py` | `optional_requires: BrainInterface`, has `_get_brain()` |
| Bridge agent | `parachute/core/orchestrator.py:1007-1011` | Retrieves BrainInterface for context enrichment |
| MCP server | `parachute/mcp_server.py:560-623` | 3 legacy tools: brain_add_episode, brain_search, brain_cypher_query |

### What the new MCP tools look like

```
get_graph_schema        → all node/rel tables with column names and types
list_conversations      → query Parachute_Session (filters: module, source, archived, limit)
get_conversation        → single session + recent exchanges
list_projects           → query Parachute_ContainerEnv (the future Project nodes)
list_entries            → Daily Entry nodes (filters: date range, limit)
```

The schema tool is the load-bearing piece — it lets an agent understand what tables exist before calling the per-table tools.

---

## Phase 1 — Remove Brain_Entity layer (server)

**Files**: `modules/brain/module.py`, `modules/brain/manifest.yaml`, `modules/chat/module.py`, `modules/chat/manifest.yaml`, `modules/daily/module.py`, `modules/daily/manifest.yaml`, `parachute/core/orchestrator.py`, `parachute/mcp_server.py`

### 1a. Gut BrainModule

In `modules/brain/module.py`:
- Remove `ensure_node_table("Brain_Entity", ...)` and `ensure_rel_table("Brain_Relationship", ...)` from `on_load()`
- Remove REST endpoints: `/types`, `/entities`, `/search`, `/cypher`, `/episodes`, `/queries`, `/relationships`, `/traverse`
- Remove `BrainService` initialization and `_ensure_service()`
- Remove public interface methods: `upsert_entity`, `search`, `recall`, `add_episode`
- Remove `registry.publish("BrainInterface", self)`
- Remove `provides: [BrainInterface]` from `manifest.yaml`
- **Decision point**: if the module shell has no remaining purpose, remove the module entirely. If Brain tab needs dedicated routes in the interim, keep a minimal shell with no entity logic.

### 1b. Clean up Chat module

In `modules/chat/module.py`:
- Remove `_get_brain()` and any calls to `brain.add_episode()` or `brain.recall()`
- Remove `requires: [BrainInterface]` from `modules/chat/manifest.yaml`

### 1c. Clean up Daily module

In `modules/daily/module.py`:
- Remove `_get_brain()` and any calls to brain interface methods
- Remove `optional_requires: [BrainInterface]` from `modules/daily/manifest.yaml`

### 1d. Clean up orchestrator

In `parachute/core/orchestrator.py`:
- Remove `registry.get("BrainInterface")` usage at line 1007-1011
- Remove any bridge agent context enrichment that depends on brain recall/search

### 1e. Remove legacy MCP tools

In `parachute/mcp_server.py`:
- Remove `brain_add_episode` tool definition and handler (lines 561-589, 1302-1309)
- Remove `brain_search` tool definition and handler
- Remove `brain_cypher_query` tool definition and handler

---

## Phase 2 — Add graph router to core (server)

**New file**: `parachute/api/graph.py`
**Modified**: `parachute/server.py` (mount the router)

### Endpoints

```
GET /api/graph/schema
    → { tables: [{ name, type, columns: [{ name, type }] }] }
    → Calls graph.execute_cypher("CALL table_info()") or equivalent

GET /api/graph/sessions
    → List Parachute_Session nodes
    → Query params: module, source, archived, limit (default 20), offset

GET /api/graph/sessions/{session_id}
    → Single session node

GET /api/graph/container_envs
    → List Parachute_ContainerEnv nodes (the future Project nodes)

GET /api/graph/daily/entries
    → List Daily Entry nodes
    → Query params: date_from, date_to, limit
```

All endpoints use `graph.execute_cypher()` via the shared GraphService from the registry. No module dependency — just core infrastructure.

---

## Phase 3 — New MCP graph tools

**Modified**: `parachute/mcp_server.py`

Replace the 3 removed brain tools with:

```python
{
    "name": "get_graph_schema",
    "description": "Returns all node and relationship tables in the graph database with their column names. Call this first to understand what data is queryable.",
    "input_schema": { "type": "object", "properties": {} }
}

{
    "name": "list_conversations",
    "description": "List conversation sessions from the graph.",
    "input_schema": {
        "properties": {
            "module": { "type": "string", "description": "Filter by module: chat, daily" },
            "limit": { "type": "integer", "default": 20 },
            "archived": { "type": "boolean", "default": false }
        }
    }
}

{
    "name": "get_conversation",
    "description": "Get a single conversation session by ID.",
    "input_schema": { "properties": { "session_id": { "type": "string" } }, "required": ["session_id"] }
}

{
    "name": "list_projects",
    "description": "List named project environments (containers).",
    "input_schema": { "properties": { "limit": { "type": "integer", "default": 20 } } }
}

{
    "name": "list_entries",
    "description": "List Daily journal entries.",
    "input_schema": {
        "properties": {
            "date_from": { "type": "string", "description": "YYYY-MM-DD" },
            "date_to": { "type": "string", "description": "YYYY-MM-DD" },
            "limit": { "type": "integer", "default": 20 }
        }
    }
}
```

Each handler calls the corresponding `/api/graph/` endpoint internally (or calls GraphService directly).

---

## Phase 4 — App: Brain tab as graph navigator

**Modified**: `app/lib/features/brain/` (significant rework)

- Remove `BrainEntity` model, providers, and entity list UI
- Brain tab now calls `GET /api/graph/schema` on load to discover all tables
- Renders a list of node tables; tapping a table calls `GET /api/graph/{table}` and renders the results as a simple key-value list
- No entity type sidebar, no form builder — just raw graph browsing
- Keep the tab label "Brain" and its position in the nav

**Files to remove**: `brain_entity.dart`, entity providers, entity form widgets
**Files to rewrite**: `brain_screen.dart`, `brain_provider.dart` (or equivalent)

---

## Phase 5 — App: Remove Vault tab

**Modified**: `app/lib/core/providers/app_state_provider.dart`, `app/lib/main.dart` (or wherever AppTab is used)

- Remove `AppTab.vault` from the enum
- Remove its entry from the `IndexedStack` children and bottom nav
- Remove `VaultScreen` import/widget from the stack
- Update `AppMode.full` tab list to `[AppTab.chat, AppTab.daily, AppTab.brain]`

---

## Dependencies & Risks

- **Brain module removal**: `real-ladybug` package dependency was only in the brain module. If the module is removed entirely, it can be dropped from `requirements.txt`. Verify no other code imports `real_ladybug` directly.
- **Graph schema introspection**: LadybugDB / Kuzu's `CALL table_info()` or equivalent needs to be verified — confirm the exact Cypher for listing tables and columns before implementing `/api/graph/schema`.
- **Daily module schema**: Daily registers `Entry`, `Card`, `Caller` tables in `on_load()`. These remain untouched — just verify they still register without the BrainInterface dependency.
- **Existing data**: Any existing `Brain_Entity` nodes in `~/.parachute/graph/parachute.kz` will remain in the DB (tables aren't dropped, just no longer created or queried). A migration to drop the tables is optional and can be deferred.

## References

- Brainstorm: `docs/brainstorms/2026-03-04-graph-as-core-infrastructure-brainstorm.md`
- `computer/parachute/db/graph.py` — GraphService API
- `computer/parachute/core/interfaces.py` — InterfaceRegistry
- `computer/modules/brain/module.py` — Current BrainModule (530 lines, all targeted for removal)
- `computer/parachute/mcp_server.py:560-623` — Legacy brain MCP tools to replace
