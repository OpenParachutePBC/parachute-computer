---
title: "refactor: Promote LadybugDB to core graph infrastructure"
type: refactor
date: 2026-03-01
modules: brain, chat, daily, computer
priority: P1
issue: 153
---

# refactor: Promote LadybugDB to Core Graph Infrastructure

## Overview

LadybugDB (Kuzu) is currently owned exclusively by the Brain module — instantiated inside `BrainModule`, connection managed by `LadybugService`, only ever used through `BrainInterface`. This was the right starting point, but the vision has expanded: the graph is the unified data layer for the whole system, not a Brain feature.

This refactor promotes LadybugDB to the same tier as the Claude Agent SDK — a core infrastructure primitive that all modules consume. Each module registers its own schema segment on load. The `BrainInterface` stays intact as the high-level brain API.

**No SQLite removal. No data migration. No user-visible changes. Infrastructure only.**

## Problem Statement

Right now `Chat_Exchange` entities are written to the graph via `BrainInterface.upsert_entity()`. That's a conceptual mismatch — a chat exchange isn't a brain entity. It happens to land in `Brain_Entity` because that's the only table available.

More broadly: as the system adds `Chat_Session`, `Journal_Entry`, `Day`, and other module-owned types, they all need the graph but shouldn't go through a brain-flavored API. The graph needs to be accessible as infrastructure, not borrowed from a module.

## Proposed Solution

### New file: `computer/parachute/db/graph.py`

Extract the low-level Kuzu connection management from `LadybugService` into a new `GraphService` class at the core DB tier. This class:

- Opens and holds the single shared database connection (Kuzu is embedded, one writer)
- Exposes `ensure_node_table()` and `ensure_rel_table()` so modules can register their schema on load
- Exposes `execute_cypher()` for raw queries
- Has the `_write_lock` for serialized writes
- Knows nothing about entity types, YAML schemas, or brain concepts

```python
class GraphService:
    """Core graph database service. Shared infrastructure, not a module concern."""

    async def connect(self) -> None: ...
    async def close(self) -> None: ...
    async def ensure_node_table(self, name: str, columns: dict[str, str], primary_key: str = "name") -> None: ...
    async def ensure_rel_table(self, name: str, from_table: str, to_table: str, columns: dict[str, str] = None) -> None: ...
    async def execute_cypher(self, query: str, params: dict = None) -> list[dict]: ...
    async def get_table_columns(self, table_name: str) -> set[str]: ...
```

The database file stays at `vault/.brain/brain.lbug` for now — moving it to `vault/.parachute/graph.lbug` is a later step once we're ready to signal the ownership change clearly.

### Updated `LadybugService` (brain-specific layer)

`LadybugService` slims down to brain-specific logic only: `upsert_entity`, `get_entity`, `query_entities`, `delete_entity`, `search`, `upsert_relationship`, `traverse`, `sync_schema`, `list_types_with_counts`. It now takes a `GraphService` instead of opening its own database connection.

```python
class LadybugService:
    """Brain-specific graph operations. Wraps GraphService with brain ontology logic."""

    def __init__(self, graph: GraphService, vault_path: Path): ...
```

### Server startup (`server.py`)

`GraphService` is instantiated before module loading, so modules can register their schemas during their own init:

```python
# In lifespan startup:
from parachute.db.graph import GraphService

graph = GraphService(db_path=settings.vault_path / ".brain" / "brain.lbug")
await graph.connect()
app.state.graph = graph

from parachute.core.interfaces import get_registry
get_registry().publish("GraphDB", graph)

# Then load modules as before — they can now get GraphDB from registry
module_loader = ModuleLoader(settings.vault_path)
modules = await module_loader.discover_and_load()
```

### Brain module

`BrainModule` no longer opens its own Kuzu connection. It gets `GraphDB` from the registry and passes it to `LadybugService`:

```python
async def _ensure_service(self) -> LadybugService:
    if self._service is None:
        async with self._init_lock:
            if self._service is None:
                graph = get_registry().get("GraphDB")
                svc = LadybugService(graph=graph, vault_path=self.vault_path)
                await svc.init_brain_schema()  # ensures Brain_Entity, Brain_Relationship
                self._service = svc
```

`BrainInterface` (the public API: `upsert_entity`, `search`, `recall`) is unchanged. All callers continue working without modification.

### Module schema registration pattern

With `GraphDB` available at startup, each module can call `ensure_node_table` during its init to register its schema. For Phase 0 this is groundwork only — no new tables are created yet, but the mechanism exists:

```python
# Future: Chat module init
graph = get_registry().get("GraphDB")
await graph.ensure_node_table("Chat_Session", {
    "session_id": "STRING",
    "title": "STRING",
    ...
})
await graph.ensure_rel_table("HAS_EXCHANGE", "Chat_Session", "Chat_Exchange")
```

## What Does NOT Change

- `BrainInterface` API — `upsert_entity`, `search`, `recall` signatures unchanged
- All callers of `get_registry().get("BrainInterface")` — no changes needed
- Database file location (`vault/.brain/brain.lbug`) — same path, same data
- `entity_types.yaml` schema management — stays in Brain module
- SQLite — untouched
- All module manifests — `BrainInterface` dependency stays listed
- User-visible behavior — nothing changes for users

## Files Modified

| File | Change |
|------|--------|
| `computer/parachute/db/graph.py` | **New** — `GraphService` class (core infrastructure) |
| `computer/parachute/db/__init__.py` | Export `GraphService` |
| `computer/parachute/server.py` | Instantiate `GraphService` at startup, publish to registry as `"GraphDB"` |
| `computer/modules/brain/ladybug_service.py` | Slim to brain-specific logic, take injected `GraphService` |
| `computer/modules/brain/module.py` | Get `GraphDB` from registry, inject into `LadybugService` |

## Acceptance Criteria

- [x] `GraphService` instantiates at server startup and is accessible via `get_registry().get("GraphDB")`
- [x] Brain module uses the shared `GraphService` connection — no separate Kuzu connection
- [x] All existing `BrainInterface` callers continue working without modification
- [x] Server starts cleanly with Brain module loaded
- [x] Existing Brain entities (Person, Project, etc.) are still readable and writable
- [x] `Chat_Exchange` entities still land in the graph correctly via bridge agent
- [x] `GraphService.ensure_node_table()` and `ensure_rel_table()` are implemented and idempotent

## Dependencies & Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Kuzu single-connection constraint | Low | `_write_lock` already handles serialization; shared connection is the right model |
| Brain module init order vs GraphDB availability | Low | `GraphService` instantiates before `ModuleLoader.discover_and_load()` in startup sequence |
| Regression in Brain API | Low | BrainInterface API is unchanged; covered by acceptance criteria |
| Brain module graceful degradation if GraphDB missing | Low | Add fallback log + skip if `get_registry().get("GraphDB")` returns None (mirrors current BrainInterface pattern) |

## Future Phases (not in scope)

- **Phase 1**: Chat module registers `Chat_Session` schema, dual-writes sessions to graph
- **Phase 2**: Daily module registers `Journal_Entry` and `Day` schema, ingest markdown files
- **Phase 3**: Operational data (pairing requests) migrated to graph
- **Phase 4**: SQLite retirement
- **Path rename**: Move `vault/.brain/brain.lbug` → `vault/.parachute/graph.lbug` (signals infrastructure ownership)

## References

- `computer/modules/brain/ladybug_service.py` — current LadybugService (to be split)
- `computer/modules/brain/module.py:36-66` — current BrainModule init (opens its own connection)
- `computer/parachute/core/interfaces.py` — InterfaceRegistry
- `computer/parachute/server.py:89-94` — module loading in startup sequence
- `computer/parachute/db/database.py` — pattern for core DB service (SQLite equivalent)
