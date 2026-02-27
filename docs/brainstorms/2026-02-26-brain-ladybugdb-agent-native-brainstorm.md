---
title: "brainstorm: Brain v3 — LadybugDB + Agent-Driven Knowledge Graph"
type: brainstorm
date: 2026-02-26
status: draft
priority: P1
issue: 129
modules: brain, computer, app, daily, chat
replaces: brainstorm #128 (Graphiti migration, Phase 2 + 3 archived)
---

# Brain v3: LadybugDB + Agent-Driven Knowledge Graph

## What We're Building

Replace the current Graphiti + Kuzu backend with a leaner, purpose-built knowledge graph
on LadybugDB (the actively-maintained Kuzu fork). Remove the extraction pipeline entirely.
Agents are the intelligence layer — they write structured knowledge directly to the graph
via MCP tools. The Flutter UI becomes a Tana-style entity browser and editor.

The result: a personal knowledge graph that is local-first, embedded in the file system,
editable by both the user (via UI) and agents (via MCP tools), with no external API
dependencies for basic operation.

---

## Why This Direction

### What Graphiti was solving

Graphiti is a pipeline that converts unstructured text into a knowledge graph using
multiple LLM calls per episode (extraction, deduplication, contradiction handling,
relationship extraction). It exists because most systems don't have an intelligent agent
already in the loop.

### Why it's the wrong fit here

We already have Claude. The curator runs during chat sessions. The daily agent processes
journals. These agents have context, judgment, and the ability to reason about what's
worth storing. Graphiti's 3–5 LLM calls per episode are a mechanical approximation of
what our agents already do better with the right prompts.

Graphiti also requires two external API keys (Anthropic for extraction, Google for
embeddings), adds significant complexity, and is built around a passive "ingest and
extract" model that conflicts with the Tana-style active-maintenance model the UI wants.

### What LadybugDB gives us instead

LadybugDB is the Kuzu fork with active development post-Apple acquisition (7 releases in
10 weeks, open source, no CLA, same Cypher API). It's embedded, no Docker, stores to a
directory, ACID transactions, fast columnar reads. It's just a database — and that's
exactly what we need. The intelligence lives in the agents and the prompts.

---

## Core Mental Model

**Agents are the write path. The UI is the read/edit path.**

```
Curator / Daily Agent / Chat Agent
    │
    │  (well-prompted: "extract and store what matters")
    ▼
brain_upsert_entity / brain_add_relationship / brain_search  (MCP tools)
    │
    ▼
LadybugDB  (embedded, vault/.brain/ladybug/)
    │
    ▼
Flutter Brain UI  (Tana-style: browse types, view fields, edit inline)
```

No extraction pipeline. No external API keys for basic Brain operation. One thoughtful
agent call instead of 3–5 mechanical ones.

---

## Key Decisions

### 1. Schema lives in entity_types.yaml

Field definitions are stored in `vault/.brain/entity_types.yaml`, hot-reloadable at
runtime (no server restart). Agents and the UI both read the schema from this file.
The UI can edit it. Agents can propose new fields.

```yaml
Person:
  occupation: {type: text, description: "Current role or job title"}
  relationship: {type: text, description: "How they relate to Aaron"}
  organization: {type: text, description: "Company or community"}
  location: {type: text, description: "Where they're based"}

Project:
  status: {type: text, description: "active / paused / completed"}
  domain: {type: text, description: "software / writing / community"}
  collaborators: {type: text, description: "People involved"}

Area:
  description: {type: text, description: "What this area encompasses"}
  cadence: {type: text, description: "daily / weekly / seasonal"}

Topic:
  domain: {type: text, description: "Philosophy / tech / creativity"}
  status: {type: text, description: "emerging / developing / crystallized"}
```

Starting simple: all fields are text. Richer types (date, number, reference) later.

### 2. Agents write structured data directly

Agents don't "ingest episodes" — they write structured facts. The curator, after a
session, identifies what's worth storing and calls:

```
brain_upsert_entity(type="Person", name="Kevin", attributes={
  "occupation": "co-founder",
  "organization": "Regen Hub",
  "relationship": "LVB co-owner, collaborator"
})
brain_add_relationship(from="Kevin", rel="co-owns", to="Learn Vibe Build")
```

The agent handles deduplication ("this Kevin is the same person from last week") by
querying first, then upserting. The agent handles conflict resolution by reasoning
about context. No framework needed.

### 3. Flutter UI is Tana-style

- Left sidebar: entity types with counts (Person, Project, Area, Topic)
- Center: entity list for selected type, showing key fields inline
- Right: entity detail with all fields editable inline
- Global search: text search across names and field values
- Schema editor: add/remove fields per type, updates entity_types.yaml immediately
- No "create episode" input — that belongs in Daily and Chat, not Brain

### 4. Multi-brain is possible, not yet exposed

The LadybugDB store path (`vault/.brain/ladybug/`) makes it trivially easy to have
multiple stores (e.g., `vault/.brain/work/`, `vault/.brain/personal/`). The MCP tools
accept an optional `store` parameter. The UI shows one brain for now. Multi-brain is
an architectural affordance, not a v1 feature.

### 5. Graphiti is removed entirely

The Phase 2 and 3 work from #128 (Daily → Brain pipeline, Chat → Brain pipeline) is
superseded. Instead of routing through Graphiti, agents write directly to LadybugDB.
The `graphiti_service.py` and `entities.py` files are deleted. No Anthropic API key
or Google API key required for Brain.

---

## What Changes from Current State

### Removed
- `graphiti_service.py` — replaced by `ladybug_service.py`
- `entities.py` — Pydantic models replaced by entity_types.yaml
- Graphiti dependency (`graphiti-core[anthropic,google-genai]`)
- Kuzu dependency → replaced by LadybugDB
- `ANTHROPIC_API_KEY` requirement for Brain
- `GOOGLE_API_KEY` / Gemini embeddings requirement

### Added
- `ladybug_service.py` — thin async wrapper around LadybugDB with Cypher
- `entity_types.yaml` — hot-reloadable schema config
- New MCP tools: `brain_upsert_entity` (replaces `brain_create_entity` + `brain_update_entity`)
- Agent prompting in curator and daily agent to write to Brain

### Flutter UI changes
- Entity cards: show actual field values (not just name + summary)
- Entity detail: inline editable fields per schema
- Schema editor: field add/remove per type
- Search: text search across fields (not semantic — that's a later enhancement)
- Hide schema management from sidebar (no "create type" from scratch for now — edit existing types via schema editor)

---

## Open Questions

1. **Search strategy** — Without Graphiti's hybrid BM25 + semantic search, what's the
   right approach? Options: (a) LadybugDB full-text search (if available), (b) simple
   Cypher substring match on name + fields, (c) store embeddings separately for semantic
   search later. Start simple, add semantic search as a Phase 2 enhancement.

2. **Relationship model** — How typed should relationships be? Graphiti uses
   `RELATES_TO` with a `fact` string. Do we want typed edge labels (`co-owns`,
   `collaborates-with`, `works-at`) or a generic labeled edge? Starting with a label +
   optional description seems right.

3. **Agent prompting strategy** — How do we instruct agents to write to Brain without
   polluting their context budget? This is a system prompt architecture question, not
   just a Brain question. If Brain-writing is something agents do on every run, it
   belongs in the base system prompt / core agent instructions — not a per-call skill
   (which risks loading schema into every context unnecessarily). Agent skills may be
   right for targeted operations ("add a new entity type", "run a complex query") but
   not for the ambient "always be aware of Brain" baseline. Deferred — this whole layer
   deserves a focused session on system prompt architecture once the data layer is solid.

4. **Temporal metadata** — Do we track when knowledge was added/updated? Minimum:
   `created_at` and `updated_at` on every node. No complex temporal invalidation like
   Graphiti. If something changes, the agent overwrites the field.

5. **Migration from current Graphiti state** — Phase 1 committed but no real data yet
   (no journals ingested). Clean cutover is fine.

6. **LadybugDB maturity** — It's 10 weeks old as an independent project. Worth doing a
   quick spike to verify install, basic Cypher, and Python bindings work cleanly before
   fully committing.

---

## What We're NOT Building (Yet)

- Semantic/vector search (text search is fine to start)
- Multiple brains in the UI (architecture supports it, not exposed)
- Temporal knowledge graph (Graphiti's main value prop — not needed)
- Automatic extraction pipeline (agents handle this with prompts)
- Graph visualization (cool, not core)
- Community detection / clustering

---

## References

- LadybugDB: https://github.com/ladybugdb/ladybugdb (Kuzu fork, active)
- Previous brainstorm (Graphiti): docs/brainstorms/2026-02-25-brain-graphiti-migration-brainstorm.md
- Issue #128 (Graphiti migration — Phase 2/3 to be archived): GitHub #128
- Tana (inspiration for UI model): https://tana.inc
