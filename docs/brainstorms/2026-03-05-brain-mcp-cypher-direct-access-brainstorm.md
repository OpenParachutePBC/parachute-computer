---
date: 2026-03-05
topic: brain-mcp-cypher-direct-access
status: brainstorm
priority: P2
issue: "#199"
---

# Brain MCP: Direct Cypher Access

## What We're Building

Replace the existing TerminusDB-era brain MCP tools (entity CRUD abstraction) with a minimal,
direct interface to the Kuzu graph database. The new tools expose Cypher passthrough and schema
inspection — no abstraction layer, no entity model, no CRUD wrapping.

The result: agents and developers can query and mutate the graph directly using Cypher, explore
the schema to understand what tables exist, and do anything Kuzu supports without being funneled
through a high-level API that may not match the actual data model.

## Why This Approach

The previous brain MCP tools (brain_create_entity, brain_query_entities, etc.) were built for
TerminusDB's document-oriented model. TerminusDB is gone. Kuzu/LadybugDB is the graph backend
for both brain entities and all session/daily data.

Rather than rebuild a semantic abstraction layer, we're cutting straight to Cypher passthrough.
Kuzu's Cypher dialect is expressive enough to handle everything the old tools did — and anything
they couldn't. Agents that write Cypher can do schema exploration, complex traversals, bulk
deletes, and upserts with a single tool.

The schema inspection tools exist specifically because agents need to discover table names and
column types before they can write useful Cypher — raw `show_tables()` output from Cypher is
valid but presenting it as a structured tool makes self-directed exploration much smoother.

## Key Decisions

- **Pure Cypher passthrough**: No CRUD wrappers, no entity abstraction. Agents write Cypher directly.
- **Schema tools as first-class**: `graph_schema()` and `graph_table_info()` return structured data
  to make schema-first exploration natural without requiring the caller to know Kuzu's `CALL` syntax.
- **Replace existing brain MCP tools**: The old entity tools are removed, not complemented. This
  is a clean break, not a layering.
- **Single tool for reads and writes vs. split**: Open question for plan phase (see below).
- **Scope — brain module or shared MCP server**: Kuzu backs all modules (Chat, Daily, Brain).
  These tools could live in the main Parachute MCP server rather than the brain module. TBD.

## Proposed Tool Set

```
graph_schema()
  → Returns all tables with column names and types (structured JSON)

graph_table_info(table_name: str)
  → Returns detailed column info for a specific table (types, primary keys)

graph_cypher(query: str, params?: dict)
  → Executes any Cypher query (read or write) against the Kuzu graph
  → Returns results as list of dicts
```

Three tools total. Minimal surface area.

## Open Questions

- **Read/write separation**: Should `graph_cypher` be one tool, or should reads (`graph_query`)
  and writes (`graph_execute`) be separate tools? Splitting signals intent to agents and could
  allow read-only trust contexts in the future.
- **Where does it live?**: Brain module MCP (`vault/.modules/brain/mcp_tools.py`) vs. the built-in
  Parachute MCP server (`computer/parachute/mcp_server.py`). Since Kuzu is shared infrastructure
  and not brain-specific, the main MCP server may be more appropriate.
- **Parameter safety**: Raw Cypher with params is already injection-safe via LadybugDB's param
  binding. But f-string interpolation in complex queries is a known footgun (see MEMORY.md).
  Should the tool warn about this, or is it out of scope?
- **Trust level gating**: Should write Cypher require a higher trust level than read Cypher?
  The hook system could enforce this if needed.

## Next Steps

→ `/plan` to define the exact tool signatures, where they live, and migration path from old brain MCP tools
