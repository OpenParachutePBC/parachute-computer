---
title: "feat: Chat module graph schema — Chat_Session and Chat_Exchange nodes"
type: feat
date: 2026-03-01
modules: chat, computer
priority: P2
issue: 155
---

# feat: Chat Module Graph Schema

## Overview

Phase 1 of the SQLite-thinning arc. The Chat module registers its own schema
segment in the shared graph (`Chat_Session` and `Chat_Exchange` node tables),
and the bridge agent writes exchanges directly into `Chat_Exchange` instead of
smuggling them through `Brain_Entity` as a hack.

No SQLite removal. No user-visible changes. One data model hack eliminated.

## Problem Statement

`Chat_Exchange` records currently land in `Brain_Entity` via
`brain.upsert_entity(entity_type="Chat_Exchange", ...)`. This is wrong:

1. Brain_Entity is the brain module's table — chat data doesn't belong there
2. `Chat_Exchange` appears as an entity type in brain schema listings, confusing users
3. There's no `Chat_Session` node — sessions only exist in SQLite, invisible to the graph
4. There's no way to traverse from a session to its exchanges in the graph

## Proposed Solution

### Step 1 — Chat module schema registration

`ChatModule` gets `GraphDB` from the registry during `__init__` (or lazy-init)
and registers three tables:

```python
await graph.ensure_node_table("Chat_Session", {
    "session_id": "STRING",   # PRIMARY KEY — matches sessions.id in SQLite
    "title": "STRING",
    "module": "STRING",
    "source": "STRING",
    "agent_type": "STRING",
    "created_at": "STRING",
}, primary_key="session_id")

await graph.ensure_node_table("Chat_Exchange", {
    "exchange_id": "STRING",        # PRIMARY KEY — "{session_id[:8]}:ex:{n}"
    "session_id": "STRING",
    "exchange_number": "STRING",
    "description": "STRING",        # Haiku summary (BM25 search target)
    "user_message": "STRING",
    "ai_response": "STRING",
    "context": "STRING",            # Session summary at time of exchange
    "session_title": "STRING",
    "tools_used": "STRING",
    "created_at": "STRING",
}, primary_key="exchange_id")

await graph.ensure_rel_table(
    "HAS_EXCHANGE", "Chat_Session", "Chat_Exchange"
)
```

`ChatModule` does this once on load. No lazy-init needed — schema registration
is idempotent and fast.

### Step 2 — Bridge agent writes to Chat_Exchange directly

`bridge_agent._store_exchange()` currently calls `brain.upsert_entity()`.
Replace with a direct `GraphDB` write:

```python
# Before (hack — lands in Brain_Entity):
await brain.upsert_entity(entity_type="Chat_Exchange", name=exchange_name, attributes=attrs)

# After (correct — lands in Chat_Exchange):
graph = get_registry().get("GraphDB")
if graph:
    await graph.execute_cypher(
        "MERGE (e:Chat_Exchange {exchange_id: $exchange_id}) SET ...",
        {"exchange_id": exchange_name, ...}
    )
```

The exchange name/id stays the same (`"{session_id[:8]}:ex:{n}"`), just the
destination table changes.

### Step 3 — Lazy-upsert Chat_Session on first exchange

Rather than touching the session-create path, the bridge agent upserts a
`Chat_Session` node the first time it stores an exchange for that session.
It already has the session object from SQLite at this point:

```python
# Upsert Chat_Session node (idempotent)
await graph.execute_cypher(
    "MERGE (s:Chat_Session {session_id: $session_id}) "
    "ON CREATE SET s.title = $title, s.module = $module, "
    "s.source = $source, s.created_at = $created_at",
    {...}
)
# Create HAS_EXCHANGE relationship
await graph.execute_cypher(
    "MATCH (s:Chat_Session {session_id: $sid}), "
    "(e:Chat_Exchange {exchange_id: $eid}) "
    "MERGE (s)-[:HAS_EXCHANGE]->(e)",
    {...}
)
```

This means `Chat_Session` nodes are created lazily (on first exchange stored),
which is fine — sessions with zero exchanges don't need a graph node yet.

### Step 4 — Clean up Brain_Entity Chat_Exchange records (optional)

If any `Chat_Exchange` entities already exist in `Brain_Entity`, they can be
left alone (they won't interfere) or migrated. Decision at implementation time
based on what's actually in the DB.

## Files Modified

| File | Change |
|------|--------|
| `computer/modules/chat/module.py` | Add async `_init_schema()`, call on load via `get_router()` or new `on_load()` hook |
| `computer/parachute/core/bridge_agent.py` | `_store_exchange()` writes to `Chat_Exchange` via `GraphDB`; add `Chat_Session` upsert + `HAS_EXCHANGE` rel |

That's it — two files.

## What Does NOT Change

- SQLite sessions table — still primary for session CRUD, listing, auth
- `BrainInterface` API — no changes
- `Brain_Entity` table — chat exchanges no longer written there (existing ones untouched)
- Flutter app — no changes
- Session create/update API — untouched
- `observe()` call signature — untouched

## Open Questions

1. **Module `on_load()` hook vs `get_router()`**: Schema registration needs to
   be async, but `ChatModule.__init__` is sync and `get_router()` returns a
   router. Cleanest option: check if other modules have an async init pattern,
   or add an `async def on_load()` that `ModuleLoader` calls after init.

2. **Existing Brain_Entity Chat_Exchange records**: Check at implementation time.
   If the DB has them, decide whether to migrate or leave.

## Acceptance Criteria

- [x] `Chat_Exchange` node table exists in the graph (not `Brain_Entity`)
- [x] `Chat_Session` node table exists in the graph
- [x] `HAS_EXCHANGE` rel table exists
- [x] New exchanges land in `Chat_Exchange`, not `Brain_Entity`
- [x] Each new exchange creates (or merges) a `Chat_Session` node
- [x] Each new exchange creates a `HAS_EXCHANGE` rel from session to exchange
- [x] Existing `Brain_Entity` entries with `entity_type = "Chat_Exchange"` do not cause errors
- [x] Server starts cleanly, Brain module unaffected
- [x] 489 unit tests still pass

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| Async schema registration in sync `__init__` | Use `ModuleLoader` async `on_load()` hook or `get_router()` — inspect at implementation time |
| `MERGE` on `Chat_Exchange` in write-heavy turns | Already serialized through `GraphService._write_lock`; no new risk |
| Existing `Chat_Exchange` in `Brain_Entity` | Non-destructive: old records stay, new ones go to correct table |

## References

- `computer/modules/chat/module.py` — ChatModule (thin, no graph today)
- `computer/parachute/core/bridge_agent.py:280-333` — `_store_exchange()` (the hack)
- `computer/parachute/db/graph.py:98-128` — example `Chat_Session` / `HAS_EXCHANGE` DDL already in comments
- `computer/parachute/db/database.py:22-37` — SQLite sessions schema (columns to mirror)
- Issue #153 / PR #154 — Phase 0 (GraphService as core infrastructure)
