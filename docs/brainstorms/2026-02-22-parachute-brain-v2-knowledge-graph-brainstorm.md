---
date: 2026-02-22
topic: parachute-brain-v2-knowledge-graph
status: ready-for-planning
priority: P1
---

**Issue:** #94

# Parachute Brain v2: TerminusDB Knowledge Graph

## What We're Building

A strongly-typed, version-controlled knowledge graph for Parachute Brain that bridges the best aspects of Obsidian (portability, vault interoperability) and Tana (structured data, supertags, typed entities, field inheritance).

**Core capabilities:**
- **Real graph database** with bidirectional relationships and traversal (not just markdown with links)
- **Strong typing & schema enforcement** via declarative schema files (like TerminusDB)
- **Agent-first interaction** - agents as primary consumers/creators of graph data through MCP tools
- **Dynamic query system** - graph traversal and pattern matching beyond simple search
- **Version controllable** - data versioning built-in, schema exports to git
- **Vault interoperability** - coexists with other Parachute modules and potential future Obsidian integration

## Why TerminusDB

After researching multiple approaches, we chose **TerminusDB as the graph engine** because:

1. **Built-in versioning** - Git-like push/pull/branch/merge for both data and schema
2. **Strong typing** - JSON schema definitions provide Tana-like supertags with field inheritance
3. **Powerful queries** - WOQL (Web Object Query Language) supports graph traversal and pattern matching
4. **Proven performance** - Succinct data structures, ~13.57 bytes/triple, faster than Neo4j for path queries
5. **Active maintenance** - v12.0.0 released December 2025, ongoing development
6. **Docker-based** - Already required for other Parachute features (sandboxed agents)

**Trade-off accepted:** Storage is binary (not human-readable files). We'll use periodic RDF/JSON exports for git archival and transparency when needed.

## Key Design Decisions

### 1. Clean Slate (No Migration)
Brain v2 starts fresh with TerminusDB storage. Existing markdown entities remain as-is for reference, but no automatic migration from old format.

### 2. Declarative Schema Files
Schema defined in `vault/.brain/schemas/*.yaml` (version controlled), compiled to TerminusDB JSON schemas. Provides type safety and validation.

### 3. Agent-Native Interface
**Primary interaction through agents:**
- MCP tools expose: `create_entity`, `query_graph`, `create_relationship`, `traverse_graph`
- Schema-aware suggestions (agents get required fields when creating entities)
- Autonomous graph updates with trust level restrictions

**Human interaction (Flutter UI):**
- Progressive disclosure: start simple, reveal complexity as needed
- Slash commands (Notion-style) for entity creation
- Embedded queries in Daily journal entries (Logseq pattern)
- Views over graph (table, cards, timeline) rather than visual graph initially

### 4. Query Capabilities
Support two primary query types:
- **Graph traversal**: Navigate relationships ("show all projects connected to this person")
- **Pattern matching**: Complex conditions ("find all X where Y is related to Z and property P = value")

Defer aggregations and temporal queries for future iterations.

### 5. Vault Interoperability
Brain entities can coexist with Obsidian notes in same vault, but we're NOT tied to Obsidian-specific conventions (wikilinks, dataview syntax). Markdown compatibility is nice-to-have, not required.

### 6. Tana-Inspired Features
Implement core Tana concepts:
- **Supertags** (typed entity templates - Person, Project, Meeting)
- **Field inheritance** (entity types extend other types)
- **Live queries** (dynamic views that update as graph changes)
- **Bidirectional field references** (when A links to B, both sides visible)

## Implementation Approach

### Phase 1: Core Integration Prototype (MVP)
**Goal:** Validate TerminusDB integration, test core mechanics

**Components:**
1. **TerminusDB Docker setup** - `docker-compose.yml` with volume persistence
2. **Knowledge graph service** - Python service wrapping TerminusDB client with async support
3. **Basic schema** - 2-3 entity types (Person, Project, Note) with simple relationships
4. **MCP server** - Expose 3-4 core tools (create_entity, query_entities, create_relationship)
5. **FastAPI routes** - Basic CRUD endpoints for Flutter UI testing
6. **Simple Flutter UI** - Minimal entity list/create screens to validate round-trip

**Success criteria:**
- Agent can create entities with schema validation
- Agent can query graph and traverse relationships
- Data persists across server restarts
- Schema changes don't break existing data (weakening changes)

### Phase 2: User Experience Iteration
**After MVP works:**
- Slash command interface for entity creation
- Embedded queries in Daily journal
- Schema editor UI
- Export to RDF/JSON for git archival
- View system (table, cards, timeline)

### Phase 3: Advanced Features
**Future enhancements:**
- Visual graph explorer (optional power feature)
- Full WOQL query editor
- Temporal queries (history/versioning)
- Aggregations and analytics
- Natural language query translation

## Technical Architecture

```
User/Agent
    ↓
MCP Tools / FastAPI
    ↓
KnowledgeGraphService (Python, async wrappers)
    ↓
terminusdb-client (sync library)
    ↓
TerminusDB (Docker container)
    ↓
Storage (binary succinct data structures)
    ↕
Periodic RDF/JSON exports → vault/.brain/exports/ (git archival)
```

**Schema flow:**
```
vault/.brain/schemas/*.yaml
    ↓ (on startup or schema change)
TerminusDB JSON schema compilation
    ↓
Schema validation enforced on writes
```

**Trust levels:**
- **Sandboxed**: Read-only access to exported RDF snapshots
- **Vault**: Read/write entities, restricted to vault-scoped schemas
- **Full**: All operations including schema modification, push/pull to remote

## Open Questions for Planning Phase

1. **Schema compilation**: Should we auto-compile YAML → TerminusDB schema on startup, or require manual sync?
2. **Relationship syntax**: How should schemas define relationship types? Separate schema file or inline?
3. **Default entity types**: What's the minimal set for MVP? Person, Project, Note? Add Meeting, Task?
4. **MCP tool granularity**: Single `brain_operation(action, params)` tool or separate tools per action?
5. **Export frequency**: Real-time RDF export on every commit, or scheduled/manual export?
6. **UI framework**: Reuse existing Brain UI patterns or build fresh for graph model?
7. **Migration strategy (future)**: If users want to import old markdown entities later, what's the import path?

## Why This Matters

Current Brain is a minimal file-based entity store with substring search. This upgrade enables:

- **Agents build knowledge over time** - Context accumulates in structured, queryable graph
- **Rich relational queries** - "Find all meetings where I discussed AI projects with founders"
- **Schema evolution** - Entity types can change without breaking existing data
- **Collaboration** - Push/pull knowledge graphs between instances (personal ↔ team)
- **Trustworthy memory** - Strong typing prevents invalid data, version control enables auditing

Parachute becomes a true extended mind system: agents don't just chat, they build and query a persistent, structured model of your world.

## Next Steps

→ Run `/para-plan` with this brainstorm to create detailed implementation plan for Phase 1 (MVP)
