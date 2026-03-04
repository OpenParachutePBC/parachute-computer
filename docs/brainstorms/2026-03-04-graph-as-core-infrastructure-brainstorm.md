---
date: 2026-03-04
topic: graph-as-core-infrastructure
status: brainstorm
priority: P1
labels: brainstorm, brain, computer, app
issue: "#187"
---

# Graph as Core Infrastructure

## What We're Building

A conceptual and architectural shift: the Kuzu graph database stops being something the Brain *module* owns and becomes core server infrastructure that all modules build on. "Brain" is the graph — not a plugin, not a module, not an optional add-on.

In practical terms this means:
- The `BrainModule` (and its `BrainInterface`) dissolves into the core server layer
- Node tables (`Brain_Entity`, `Brain_Relationship`) go away for now — deferred until there's a clear need
- Chat and Daily register their own schema segments (Conversation, Exchange, Day, JournalEntry)
- The graph is the single source of truth for session metadata, structure, and eventually memory
- The Brain tab in the app becomes a graph navigator — a power-user UI for browsing and querying the whole graph across all tables

## Why This Approach

The current setup has Brain as a module that provides `BrainInterface` (add_episode, search, recall) and other modules depend on it. This creates an awkward layering: Brain is simultaneously a feature (entity memory) and infrastructure (shared DB access). Those two roles shouldn't be conflated.

Moving graph capabilities into core resolves this. Modules become simpler — they just register their node tables and use the graph for what they need. The "memory" layer (entities discovered across conversations) is deferred until there's a clearer picture of what it should look like.

## Key Decisions

- **Graph lives in core, not a module**: `GraphService` / `GraphDB` stays in `parachute/core/` or `parachute/db/`. No module "owns" it.
- **BrainInterface → core API**: `add_episode`, `search`, `recall` become core graph methods (or are dropped temporarily while the entity layer is deferred).
- **Brain_Entity / Brain_Relationship dropped for now**: YAGNI. When a memory/entity layer is reintroduced, it'll be designed intentionally.
- **Schema ownership by module segment**: Each module registers its own node tables. Core owns `Project` + `Conversation`. Chat owns `Exchange`. Daily owns `Entry` (Notes) + `Card` + `Caller`. No cross-cutting entity or memory layer for now.
- **Brain tab = graph navigator**: Stays as a primary tab. Becomes a UI for browsing and querying the whole graph — all node tables, raw queries. Power-user tool.
- **Vault tab**: Likely drops as a primary nav tab. File browsing surfaces within project context.
- **MCP graph tools**: Graph queries exposed as structured MCP tools — not raw Cypher. A `get_graph_schema` tool returns the full node/rel table structure so an agent knows what's queryable. Purpose-built query tools per entity type sit on top of that (e.g. `list_projects`, `get_conversation`, `search_entries`). The schema tool is the key enabler: without it, an agent can't use the query tools reliably.

## Relationship to Projects (Adjacent Thread)

This brainstorm focuses on the DB architecture. A related thread is the Project model: promoting `ContainerEnv` to a first-class `Project` graph entity (with core_memory, conversations, shared containers). That brainstorm is tracked separately but depends on this one — getting the graph layer right is a prerequisite.

Rough entity hierarchy once both threads land:
- `Project` → has many `Conversation` (was `Session`) → has many `Exchange`
- `Day` → has many `JournalEntry`
- (Future) `Entity` nodes for cross-cutting memory

## Open Questions

- Does the `brain` module go away entirely, or does it slim down to just providing the Brain tab's query routes?
- `Day` as a node table vs. just querying `Entry` by date — worth deciding before implementation starts
- MCP tool granularity: how many purpose-built query tools to start with? Minimum viable set is probably `get_graph_schema` + one read tool per core table.

## Next Steps

→ `/plan` for implementation: remove BrainModule ownership, move graph to core, define Chat + Daily schema segments, update Brain tab to graph navigator
