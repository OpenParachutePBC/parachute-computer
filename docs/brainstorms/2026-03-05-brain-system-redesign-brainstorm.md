---
date: 2026-03-05
topic: brain-system-redesign
status: brainstorm
priority: P1
issue: "#200"
---

# Brain System Redesign: Graph IS the Brain

## What We're Building

A cohesive redesign that aligns the naming, architecture, and UI around a single clear idea:
**the brain is your extended mind — your conversations and journal entries, unified.**

The Kuzu/LadybugDB graph database is the brain. Not a module on top of it, not a separate
knowledge store — the graph itself. Sessions (conversations) and Notes (journal entries) are
both memories. The Brain tab is where you navigate them.

This is a cleanup + coherence pass, not a feature expansion. Four concrete pieces:

1. **Rename internals**: `graph` → `brain` everywhere in the stack
2. **Kill dead code**: Delete the TerminusDB-era brain module artifacts
3. **MCP tools**: Expose Cypher passthrough so agents can query and write the full brain
4. **Brain tab redesign**: From table inspector to memory navigator

## Why This Approach

The March 4 dissolution moved Kuzu from a brain-module-owned store to core infrastructure.
That was architecturally correct, but it left a naming incoherence: the user-facing concept is
"Brain," but the code calls everything "graph" (GraphService, /api/graph/, graph.py). The
Flutter Brain tab became a database inspector because no one decided what it should be instead.

The bet here is that brain = sessions + notes is the right starting model. No separate entity
store, no TerminusDB, no YAML schemas. Your conversations and journal entries *are* your
extended memory. Option 3 (synthesis, connection-making, "ask the brain") grows naturally from
this foundation once the unified data is queryable.

## Key Decisions

- **Brain IS the graph**: No separate `Brain_Entity` table. Sessions and Notes are the memory.
  Entity store may re-emerge later if the need surfaces, but not a priority now.
- **`graph` → `brain` rename**: Internal names should match the conceptual name. GraphService →
  BrainService, /api/graph/ → /api/brain/, graph.py → brain.py, MCP tools brain_* throughout.
- **Delete vault/.modules/brain/**: The whole directory is dead code (TerminusDB-era, never
  loaded). Remove it cleanly rather than leaving it as a trap.
- **Cypher passthrough for MCP**: Agents get `brain_schema()`, `brain_query(cypher, params)`,
  and `brain_execute(cypher, params)`. Read/write split is intentional — signals intent and
  allows future trust-level gating. See issue #199 for original MCP brainstorm.
- **Memory Feed UI**: Brain tab becomes a chronological unified view of sessions + notes.
  Time-organized, not feature-organized. Search is the primary navigation.

## The Brain Tab Design

A "memory feed" — chronological, mixing conversations and journal entries as equal memories.

```
┌─────────────────────────────────┐
│  🔍  Search your memory...      │
├─────────────────────────────────┤
│  All  ·  Conversations  ·  Notes│
├─────────────────────────────────┤
│  Today                          │
│  💬  Brain audit brainstorm     │
│      Chat · 2 hours ago         │
│  📓  Morning voice note         │
│      Daily · 9:14am             │
│                                 │
│  Yesterday                      │
│  💬  LVB Week 2 prep            │
│      Chat · 4:30pm              │
│  ...                            │
└─────────────────────────────────┘
```

- Tap conversation → opens in Chat
- Tap note → opens in Daily for that day
- Search spans both types
- Filter chips: All / Conversations / Notes
- Date grouping: Today / Yesterday / This Week / etc.

Why this over a table inspector: the organizational unit is *time*, not *feature*. You're
browsing memory, not navigating an app.

Foundation for Option 3: once everything is unified and searchable, "ask the brain" (Claude
querying the full graph) becomes a natural next step.

## Rename Scope

Backend:
- `computer/parachute/db/graph.py` → `brain.py` (class GraphService → BrainService)
- `computer/parachute/api/graph.py` → `brain.py` (routes /api/graph/* → /api/brain/*)
- All internal references to GraphService, graph_db, execute_cypher context
- MCP tool names in mcp_server.py: get_graph_schema → brain_schema, etc.

Frontend:
- `GraphService` → `BrainService` in Flutter providers/services
- `/api/graph/` → `/api/brain/` in API client
- Update app/CLAUDE.md to reflect current architecture (remove entity CRUD docs)

MCP:
- Existing graph query tools renamed to brain_* prefix
- New tools added: brain_query, brain_execute (Cypher passthrough)

## Dead Code to Delete

- `computer/vault/.modules/brain/` — entire directory (TerminusDB-era, never loaded)
  - module.py, knowledge_graph.py, mcp_tools.py, models.py, schema_compiler.py
  - manifest.yaml, README.md
- Remove TerminusDB references from requirements/docs
- Update `computer/CLAUDE.md` — remove brain module documentation
- Update `app/CLAUDE.md` — remove entity CRUD feature documentation

## Open Questions

- **Migration safety**: /api/graph/ → /api/brain/ is a breaking change if any external clients
  use the API directly. Low risk (local-only server), but worth noting.
- **Search implementation**: The memory feed's search needs to span Chat titles + Note content.
  Is full-text search in Kuzu good enough, or do we need a separate index?
- **BrainService in server.py**: The lifespan manager currently inits GraphService directly.
  Rename is mechanical but touches several files.
- **MCP server placement**: brain_query/brain_execute should live in the main Parachute MCP
  server (mcp_server.py), not the brain module, since Kuzu is shared infrastructure.

## Relationship to #199

Issue #199 (Brain MCP: Direct Cypher Access) is a sub-piece of this. The MCP tool design from
that brainstorm stands — brain_schema, brain_query, brain_execute — it just now sits within the
broader rename and redesign context.

## Next Steps

→ `/plan` to break into sequenced work: (1) rename + cleanup, (2) MCP tools, (3) Brain tab UI
