---
title: "feat: Migrate Brain to Graphiti with Daily and Chat extraction pipelines"
type: feat
date: 2026-02-25
issue: 128
modules: brain, daily, chat, computer
priority: P1
---

# feat: Migrate Brain to Graphiti with Daily and Chat Extraction Pipelines

## Overview

Replace the Brain module's TerminusDB backend with Graphiti + Kuzu and build the Daily → Brain and Chat → Brain extraction pipelines. The result is a personal knowledge graph that populates itself: Aaron writes journals and has conversations; the agent translates text to structured entities automatically.

No production data exists in TerminusDB — this is a clean cutover. The 14 existing MCP tool names are preserved. Only the internal backend changes.

**Kuzu status note**: Kuzu was acquired by Apple in October 2025 and archived — no new development. The last stable release is functional with no known critical issues. The fork ecosystem (LadybugDB, RyuGraph, Bighorn) is still settling. Use the stable Kuzu release now; migrate to the community fork winner when one emerges. Migration is a one-line import swap — all forks are drop-in replacements with the same Cypher API. Neo4j is the fallback if Kuzu's archived state causes a real problem before a fork wins.

---

## Problem Statement

TerminusDB was the right choice for Phase 1 MVP: schema enforcement, CRUD, relationships, traversal, 14 MCP tools, Docker setup, YAML schema compiler — all working. But it has no LLM extraction pipeline. Building "journal text → structured entities" on top of TerminusDB means building Graphiti from scratch.

Graphiti (`getzep/graphiti`) is purpose-built for this: temporal knowledge graph engine with LLM entity extraction, deduplication, contradiction detection, and hybrid search built in. Keeping TerminusDB blocks the whole Brain value proposition.

---

## Proposed Solution

**Three phases** delivered in order:

1. **Phase 1 — Backend Replacement**: Swap TerminusDB for Graphiti + Kuzu. Keep all 14 MCP tools. Add 3 new agent-native tools.
2. **Phase 2 — Daily → Brain Pipeline**: Hook journal creation into `add_episode`. Provide a manual bulk import script for the existing ~162 journal files.
3. **Phase 3 — Chat → Brain Pipeline**: Extend the curator with a `brain_add_episode` MCP tool that ingests chat sessions into the knowledge graph at session close.

---

## Technical Approach

### Architecture

```
App (Flutter)
    │
    ▼
MCP Server (mcp_server.py) — 17 Brain tools (14 existing + 3 new)
    │
    ▼
Brain Module HTTP API (/api/brain/*)
    │
    ▼
BrainModule (module.py)
    │
    ▼
GraphitiService (graphiti_service.py)  ←  replaces knowledge_graph.py
    │
    ▼
Graphiti client
    │
    ▼
Kuzu (embedded, vault/.brain/kuzu/)
    │ (fallback: Neo4j via docker-compose.brain.yml)
```

```
Daily module (create_entry)
    │
    ▼
brain.add_episode(entry_text, reference_time=entry_ts)
    │
    ▼
Graphiti → Claude Sonnet extraction → Person/Project/Area/Topic nodes
    │
    ▼
Kuzu (same database)
```

```
Chat session closes (session-end lifecycle event)
    │
    ▼
Curator (curator_mcp.py) calls brain_add_episode(full_transcript, session_id)
    │
    ▼
brain.add_episode(session_text, source_description="Chat session {id}")
    │
    ▼
Graphiti → extraction → merged entity graph
```

> **Open question**: The curator fires at exchange cadence ({1,3,5} then every 10th), not at session end. A session could close without triggering a curator run. Resolution options: (a) add a session-end hook in the orchestrator that explicitly calls Brain's `add_episode`, (b) ingest incrementally every N exchanges, (c) a nightly scheduled agent as fallback. To be decided during Phase 3 implementation.

### Entity Schema (`modules/brain/entities.py` — new file)

```python
from pydantic import BaseModel, Field
from typing import Optional

class Person(BaseModel):
    occupation: Optional[str] = Field(None, description="Current role or job title")
    relationship_to_user: Optional[str] = Field(None, description="How they relate to Aaron: friend, collaborator, family, mentor, client")
    organization: Optional[str] = Field(None, description="Company, community, or group they're part of")
    location: Optional[str] = Field(None, description="Where they're based, if mentioned")

class Project(BaseModel):
    status: Optional[str] = Field(None, description="Current status: active, paused, completed, abandoned")
    domain: Optional[str] = Field(None, description="Domain: software, writing, community, business, research, art")
    deadline: Optional[str] = Field(None, description="Target date or deadline if mentioned")
    collaborators: Optional[str] = Field(None, description="People working on this with Aaron")

class Area(BaseModel):
    description: Optional[str] = Field(None, description="What this area encompasses")
    current_focus: Optional[str] = Field(None, description="What Aaron is actively working on in this area right now")
    cadence: Optional[str] = Field(None, description="How often Aaron engages: daily, weekly, seasonal")

class Topic(BaseModel):
    domain: Optional[str] = Field(None, description="Domain: philosophy, technology, creativity, spirituality, business")
    related_projects: Optional[str] = Field(None, description="Projects or areas this topic connects to")
    status: Optional[str] = Field(None, description="How developed: emerging, developing, crystallized")

ENTITY_TYPES = {"Person": Person, "Project": Project, "Area": Area, "Topic": Topic}
```

Notes are not a separate type — raw journal entries live as `EpisodicNode` objects (Graphiti's native provenance layer).

### Concurrency Strategy

Kuzu is embedded (single-process). Daily ingestion and Chat ingestion both write to Brain. The solution: **asyncio.Lock at the `GraphitiService` level** serializes all writes. Read operations are not locked (Kuzu allows concurrent reads). If a write takes 30+ seconds (LLM + graph write), callers queue transparently — no errors propagate up.

**Kuzu fork watch**: Kuzu is archived (acquired by Apple, Oct 2025). Current frontrunners in the fork ecosystem: **LadybugDB** (506 stars, 7 releases in 10 weeks, dropped CLA, active feature development) and **RyuGraph** (Predictable Labs, ex-Dgraph CEO, 3 monthly releases). Track `getzep/graphiti#1132` — if/when Graphiti merges support for a fork, that's the signal to migrate. Migration is a one-line import swap.

If Kuzu's archived state causes a real problem (security CVE, Python version incompatibility), the fallback is Neo4j: `docker-compose -f docker/docker-compose.brain.neo4j.yml up -d` + one env var change. All Graphiti Cypher code is unchanged.

### Entity Identifier Contract

Post-migration, `entity_id` in MCP tools uses the entity `name` as a string (e.g., `"Parachute"` for a Project). Lookups are by `name` within the user's `group_id`. The underlying Graphiti UUID is internal only. This preserves the human-readable IRI convention without breaking callers.

`brain_get_entity(entity_id)` translates to:
```cypher
MATCH (e:Entity {name: $name, group_id: $group_id}) RETURN e LIMIT 1
```

### Group ID

Single-user system: `group_id = "user-default"` hardcoded in `GraphitiService.__init__()`. Config override available at `vault/.parachute/config.yaml`:
```yaml
brain:
  group_id: "user-aaron"
```

### MCP Tool Mapping (14 existing → Graphiti backends)

| Tool | Current (TerminusDB) | Post-migration (Graphiti) |
|------|---------------------|--------------------------|
| `brain_list_types` | Lists TerminusDB classes | Returns the 4 hardcoded Pydantic types with field descriptions |
| `brain_create_type` | Creates TerminusDB class | Returns `{"error": "Schema is defined in code. Use brain_add_episode to contribute knowledge."}` |
| `brain_update_type` | Updates TerminusDB class | Same explicit error |
| `brain_delete_type` | Deletes TerminusDB class | Same explicit error |
| `brain_create_entity` | WOQLClient insert | Calls `add_episode` with synthetic text: `"New {type}: {name}. {field}: {value}..."` |
| `brain_query_entities` | WOQLClient match | Cypher: `MATCH (n:Entity:{type}) WHERE n.group_id=$gid RETURN n LIMIT {limit}` |
| `brain_get_entity` | WOQLClient get by IRI | Cypher: `MATCH (n:Entity {name: $name, group_id: $gid}) RETURN n` |
| `brain_update_entity` | WOQLClient update | Returns `{"info": "Use brain_add_episode with updated text. Graphiti tracks temporal changes automatically."}` |
| `brain_delete_entity` | WOQLClient delete | Sets node as logically deleted: creates episode `"Aaron no longer tracks entity: {name}."` which triggers temporal invalidation |
| `brain_create_relationship` | WOQLClient link | Calls `add_episode` with text: `"{from_name} {relationship} {to_name}."` — Graphiti extracts as RELATES_TO edge |
| `brain_traverse_graph` | WOQLClient path query | Cypher: `MATCH (s {name: $start, group_id: $gid})-[*1..{depth}]-(n) RETURN DISTINCT n` |
| `brain_list_saved_queries` | Reads `queries.json` | Reads `vault/.brain/queries.json` (same format, adds optional `cypher` field) |
| `brain_save_query` | Writes filter array | Writes named query with optional `cypher` field alongside existing `filters` format |
| `brain_delete_saved_query` | Deletes from `queries.json` | Same |

**3 new tools** (MCP additions):

| Tool | Description |
|------|-------------|
| `brain_add_episode` | Ingests raw text as an episode. LLM extracts entities. Vault-trust or higher only. |
| `brain_search` | Graphiti hybrid search (semantic + BM25). Returns matching entities and facts. |
| `brain_cypher_query` | Executes a named saved Cypher query OR a direct Cypher string (vault-trust only). |

### Import Pipeline — Idempotency

A state file at `vault/.brain/import-state.json` tracks which journal dates have been processed:
```json
{
  "imported_dates": ["2025-01-01", "2025-01-02"],
  "completed": false,
  "last_run": "2026-02-25T03:00:00Z"
}
```
Re-running the import script skips dates already in `imported_dates`. Partial runs are resumable.

**Episode granularity**: One `add_episode` call **per journal entry** (not per day). Each `# para:daily:{id}` block is a separate episode with its own `reference_time` (parsed from `{date}T{HH:MM}:00`). Better temporal granularity at ~5x more LLM calls vs. one-per-day.

**Frontmatter stripping**: The parser splits on `\n# para:daily:` (matching existing `mcp_server.py` logic) and passes only body text to `add_episode`. YAML frontmatter at the top of the file is discarded.

---

## Implementation Phases

### Phase 1 — Brain Backend Replacement

**Goal**: Graphiti + Kuzu running, all 14 existing MCP tools working, 3 new tools added. TerminusDB completely removed.

#### Tasks

**1.1 — Dependency swap** (`computer/pyproject.toml`, `computer/modules/brain/manifest.yaml`)
- Remove: `terminusdb-client>=10.2.0`
- Add: `graphiti-core`, `kuzu`

**1.2 — Create `modules/brain/entities.py`**
- 4 Pydantic models: `Person`, `Project`, `Area`, `Topic`
- All fields `Optional[str]` with extraction-prompt field descriptions
- `ENTITY_TYPES` dict for passing to `add_episode`

**1.3 — Create `modules/brain/graphiti_service.py`** (replaces `knowledge_graph.py`)
- `GraphitiService` class with async methods mirroring current public API
- `__init__`: Accepts kuzu db path, group_id; creates Graphiti + Kuzu client
- `_write_lock: asyncio.Lock` — serializes all write operations
- Methods: `add_episode()`, `search()`, `query_entities()`, `get_entity()`, `create_entity_via_episode()`, `delete_entity_logical()`, `create_relationship_via_episode()`, `traverse_graph()`, `execute_cypher()`
- Connection check: `_ensure_connected()` validates Kuzu db path exists, Graphiti client is initialized
- Retry on LLM errors: exponential backoff (5s, 15s, 45s) for `add_episode`, max 3 retries

**1.4 — Delete `modules/brain/schema_compiler.py`** (TerminusDB-specific, no Graphiti equivalent)

**1.5 — Update `modules/brain/mcp_tools.py`**
- Rewrite all 14 `TOOL_HANDLERS` to call `GraphitiService` methods per the mapping table above
- Add handlers for 3 new tools: `brain_add_episode`, `brain_search`, `brain_cypher_query`
- Trust-gate `brain_add_episode` and `brain_cypher_query` to vault-trust or higher

**1.6 — Update `modules/brain/module.py`**
- Replace `KnowledgeGraphService` import with `GraphitiService`
- `_ensure_kg_service()`: initialize Graphiti with `vault/.brain/kuzu/` path + group_id from config
- `search()`: replace brute-force parallel type queries with `graphiti.search(query)` (single call)
- `get_status()`: reflect Graphiti/Kuzu state instead of TerminusDB connection status
- Remove YAML schema compiler initialization
- Update directory setup: create `vault/.brain/kuzu/` instead of TerminusDB paths

**1.7 — Update `computer/parachute/server.py`**
- Remove `validate_terminusdb_password()` function (lines 46-54)
- Remove `start_terminusdb()` function (lines 55-100)
- Remove `stop_terminusdb()` function (lines 101-127)
- Remove `TERMINUSDB_ADMIN_PASS` env var handling
- Remove `start_terminusdb()` call in `lifespan` startup (lines 267-274)
- Remove `stop_terminusdb()` call in `lifespan` shutdown (lines 301-307)
- Note: Kuzu is embedded — no Docker startup needed

**1.8 — Update `modules/brain/manifest.yaml`**
- Update `dependencies`
- Update `description` to reflect Graphiti backend

**1.9 — Update `mcp_server.py`** tool definitions
- Add `brain_add_episode` tool definition (lines after existing brain tools, ~line 572)
- Add `brain_search` tool definition
- Add `brain_cypher_query` tool definition

**1.10 — Validation (integration smoke test)**
- Write a test that spawns 3 concurrent asyncio tasks each calling `add_episode` on the same Graphiti + Kuzu instance
- Verify: no exceptions, all episodes recorded, asyncio.Lock prevents data corruption
- Verify Kuzu stable release installs cleanly on current Python version (`pip install kuzu`)
- Note: if Kuzu version incompatibility arises, pivot to Neo4j backend (same code, add `docker/docker-compose.brain.neo4j.yml`, `GRAPHITI_BACKEND=neo4j`)

#### Acceptance Criteria — Phase 1

- [ ] `parachute server -f` starts without TerminusDB Docker startup
- [ ] `curl http://localhost:3333/api/health?detailed=true` shows Brain module `connected: true`
- [ ] All 14 existing MCP tools return valid responses (no 500 errors)
- [ ] `brain_list_types` returns Person, Project, Area, Topic with field descriptions
- [ ] `brain_add_episode(text="Aaron is working on Parachute, a software project.")` creates a Project entity "Parachute"
- [ ] `brain_search(query="software project")` returns Parachute in results
- [ ] Concurrent write test passes without exceptions
- [ ] No TerminusDB Docker container running

---

### Phase 2 — Daily → Brain Pipeline

**Goal**: New journal entries automatically feed the knowledge graph. Existing ~162 journals importable via CLI.

#### Tasks

**2.1 — Hook `create_entry()` in `modules/daily/module.py`** (after line 87 where markdown is written)
```python
# After writing journal file
brain = self._get_brain()
if brain:
    entry_dt = datetime.combine(date.fromisoformat(today), time.fromisoformat(entry_time))
    asyncio.create_task(
        brain.add_episode(
            name=f"Journal {today} {entry_id}",
            episode_body=entry_content,  # frontmatter-stripped
            source_description=f"Daily journal {today}",
            reference_time=entry_dt,
        )
    )
```
Use `asyncio.create_task()` — fire-and-forget, does not block journal creation.

**2.2 — Update `BrainInterface` in `modules/brain/module.py`**
- Add public `async add_episode(name, episode_body, source_description, reference_time)` method
- Delegates to `GraphitiService.add_episode()` with `ENTITY_TYPES` and `group_id`

**2.3 — Create `computer/scripts/brain_import.py`** (standalone CLI script)
```python
# Usage: python scripts/brain_import.py --vault /path/to/vault [--dry-run] [--since 2025-01-01]
```
- Reads all `.md` files from `vault/Daily/journals/`
- Parses each file into entries (split on `\n# para:daily:`)
- Strips YAML frontmatter
- Skips dates already in `vault/.brain/import-state.json`
- Calls `add_episode_bulk` for each entry (not day)
- Updates state file as each date completes
- Exponential backoff on LLM rate limit errors
- `--dry-run` mode prints entries that would be ingested without calling LLM

**2.4 — Add `parachute brain import` CLI command** (`computer/parachute/cli.py`)
- Wraps `brain_import.py`
- Accepts `--vault`, `--since`, `--dry-run` flags
- Displays progress bar and entity count on completion

#### Acceptance Criteria — Phase 2

- [ ] Writing a new Daily journal entry causes entity extraction to run (visible in logs)
- [ ] `parachute brain import --dry-run` lists all unimported journal dates
- [ ] `parachute brain import` imports 162 journals, resuming correctly after interruption
- [ ] `brain_query_entities(entity_type="Person")` returns people mentioned in journals
- [ ] `brain_search(query="Parachute project")` returns the Parachute project entity
- [ ] Re-running `brain import` does not create duplicate EpisodicNodes for already-imported dates

---

### Phase 3 — Chat → Brain Pipeline

**Goal**: Chat sessions automatically contribute to the knowledge graph with no user action.

#### Architecture Decision: Curator Extension

The curator (`curator_mcp.py`) already bridges Chat → Daily via `log_activity` → `vault/Daily/.activity/{today}.jsonl`. It has `session_id` and `vault_path` baked in per run. Brain ingestion is a natural extension: add a `brain_add_episode` MCP tool to the curator's tool set, and call it at the appropriate point in the session lifecycle.

The curator does not do entity extraction — it just passes the session transcript text to Brain's HTTP API. Graphiti handles extraction internally via Claude Sonnet. The curator model (Haiku) and the extraction model (Sonnet) are independent.

**Open question on trigger timing**: The curator fires at exchange cadence ({1,3,5} then every 10th) — not at session end. A session could close without a final curator run. Resolution is deferred to implementation; options are: a dedicated session-end hook in the orchestrator, incremental ingestion every N exchanges, or a nightly scheduled fallback agent. Start with the simplest option and iterate.

#### Tasks

**3.1 — Add `brain_add_episode` MCP tool to curator** (`computer/parachute/core/curator_mcp.py`)
- New tool: `brain_add_episode(session_id, episode_text)` — POSTs to `/api/brain/episodes`
- Curator calls this at session end (or at cadence if session-end hook is unavailable)
- Episode body: full session transcript (fetched from session JSONL or passed directly)
- `source_description`: `"Chat session {session_id}"`
- `reference_time`: session `created_at`

**3.2 — Add `/api/brain/episodes` route** (`modules/brain/module.py`)
- `POST /api/brain/episodes` → `GraphitiService.add_episode()`
- Body: `{name, episode_body, source_description, reference_time}`
- Returns `{status: "queued"}` immediately (fire-and-forget background task)

**3.3 — Resolve session-end trigger** (implementation decision)
- Investigate whether the orchestrator (`curator.py`) has a session-close lifecycle event
- If yes: call `brain_add_episode` from the session-close path
- If no: set curator cadence to trigger on the exchange *after* a `DoneEvent` is detected, or add a nightly `brain-chat-extractor` scheduled agent as fallback

#### Acceptance Criteria — Phase 3

- [ ] Chat sessions are ingested into the Brain graph (timing TBD based on trigger approach)
- [ ] `brain_query_entities(entity_type="Person")` includes people mentioned only in chat
- [ ] Entities mentioned in both journals and chat merge correctly (deduplication)
- [ ] Ingestion does not block or delay the chat session's `DoneEvent`

---

## Alternative Approaches Considered

### Neo4j Instead of Kuzu (Immediate)

**Why rejected**: Kuzu is embedded (zero-ops, no Docker, no port management). Neo4j adds a Docker service, APOC plugin, 1GB+ RAM. For a personal PKG on a laptop, the operational overhead isn't justified until a concrete problem appears. The Kuzu stable release is functional. FalkorDB is ruled out — broken Docker image.

**Kept as fallback**: If Kuzu's archived state causes a real problem before a fork wins (CVE, Python incompatibility), migration to Neo4j is `docker-compose up + GRAPHITI_BACKEND=neo4j`. Zero Cypher changes.

### LadybugDB / RyuGraph Now Instead of Kuzu

**Why not yet**: The fork ecosystem is still settling as of Feb 2026. LadybugDB is the frontrunner (506 stars, 7 releases, dropped CLA) but Graphiti hasn't merged support yet (tracking `getzep/graphiti#1132`). Picking a fork too early risks backing the wrong project. Use stable Kuzu and migrate when the Graphiti PR merges.

### Nightly Scheduled Agent for Chat Extraction

**Why deprioritized**: A scheduled nightly agent introduces 24-hour lag and adds scheduler complexity. The curator already runs in the session context with `session_id` in scope — extending it is architecturally cleaner. The nightly agent remains a valid fallback if the curator session-end trigger proves difficult to implement.

### Preserving `brain_create_type` / `brain_update_type` as Live Operations

**Why rejected**: Graphiti's entity types are Pydantic models in Python code. Dynamic schema changes at runtime would require restarting the server or hot-reloading modules. Explicit error messages ("schema is defined in code") are cleaner than silent no-ops or complex dynamic loading.

### Exposing Direct Graphiti UUID as `entity_id`

**Why rejected**: UUIDs are opaque to agents. Agents write `brain_get_entity("Parachute")`, not `brain_get_entity("a3f7c2d1-...")`. Name-based lookup matches how agents naturally reference entities and preserves backward compatibility with any agent prompts already using the current IRI style.

---

## Acceptance Criteria

### Functional Requirements

- [ ] Brain module starts without TerminusDB Docker running
- [ ] All 14 existing MCP tool names respond without errors
- [ ] 3 new MCP tools (`brain_add_episode`, `brain_search`, `brain_cypher_query`) work correctly
- [ ] New journal entries trigger automatic entity extraction (Phase 2)
- [ ] `parachute brain import` imports all existing journals with idempotency (Phase 2)
- [ ] Chat sessions ingest into Brain graph within 24 hours (Phase 3)
- [ ] Entities from journals and chat merge correctly (deduplication)
- [ ] `brain_traverse_graph` returns connected entities from a starting node

### Non-Functional Requirements

- [ ] Concurrent write operations do not corrupt the Kuzu database
- [ ] `brain_add_episode` errors (LLM 429, timeout) retry with backoff and do not crash
- [ ] Journal ingestion does not block entry creation (fire-and-forget)
- [ ] `parachute brain import` is resumable after interruption

### Trust Level Requirements

- [ ] `brain_add_episode` and `brain_cypher_query` require vault-trust or higher
- [ ] Sandboxed agents can call read-only tools (`brain_query_entities`, `brain_search`, `brain_get_entity`) only
- [ ] `brain_traverse_graph` available at all trust levels (read-only)

---

## Dependencies & Prerequisites

- `graphiti-core` Python package (PyPI)
- `kuzu` Python package (PyPI)
- Graphiti requires `ANTHROPIC_API_KEY` for LLM extraction (same key as rest of server via `CLAUDE_CODE_OAUTH_TOKEN` or `config.yaml`)
- Existing TerminusDB Docker image can be removed from `docker/docker-compose.brain.yml` (or file deleted entirely if Kuzu)

---

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Kuzu archived state causes Python version incompatibility | Low | High | Smoke test install on current Python first (task 1.10); Neo4j fallback ready |
| No Kuzu fork wins before Kuzu breaks | Low | Medium | Track `getzep/graphiti#1132`; migrate when Graphiti merges fork support |
| Kuzu file lock under concurrent asyncio writes | Low | High | asyncio.Lock in GraphitiService serializes all writes; confirmed before Phase 2 |
| Claude Sonnet extraction quality is poor on real journal text | Medium | Medium | Iterate on field descriptions in entities.py; low-risk change |
| Graphiti `add_episode` rate-limits on bulk import | High | Low | Exponential backoff in import script; manual re-run resumes from state file |
| Phase 1 tool breakage discovered by existing agents | Low | Medium | Keep 14 tool names; test each handler before declaring done |
| Curator trigger doesn't fire at session end | Medium | Low | Nightly scheduled agent as fallback; chat entities lag 24h at worst |

---

## Files to Create / Modify

### New Files

| File | Purpose |
|------|---------|
| `computer/modules/brain/entities.py` | 4 Pydantic entity types with extraction-prompt field descriptions |
| `computer/modules/brain/graphiti_service.py` | `GraphitiService` async wrapper replacing `knowledge_graph.py` |
| `computer/scripts/brain_import.py` | Standalone bulk import script for legacy journals |

### Modified Files

| File | Changes |
|------|---------|
| `computer/modules/brain/manifest.yaml` | Swap `terminusdb-client` → `graphiti-core`, `kuzu` |
| `computer/modules/brain/module.py` | Replace KG service, update `_ensure_kg_service()`, simplify `search()` |
| `computer/modules/brain/mcp_tools.py` | Rewrite all 14 handlers + add 3 new ones |
| `computer/modules/brain/models.py` | Keep request/response models; remove TerminusDB-specific response shapes |
| `computer/modules/daily/module.py` | Hook `create_entry()` to call `brain.add_episode()` |
| `computer/parachute/server.py` | Remove `start/stop_terminusdb`, TerminusDB env var handling |
| `computer/parachute/mcp_server.py` | Add 3 new tool definitions after line 572 |
| `computer/pyproject.toml` | Swap dependencies |
| `computer/parachute/cli.py` | Add `parachute brain import` command |
| `computer/parachute/core/curator_mcp.py` | Add `brain_add_episode` tool for Chat → Brain ingestion |

### Deleted Files

| File | Reason |
|------|--------|
| `computer/modules/brain/knowledge_graph.py` | Replaced by `graphiti_service.py` |
| `computer/modules/brain/schema_compiler.py` | TerminusDB-specific, no Graphiti equivalent |
| `docker/docker-compose.brain.yml` | TerminusDB Docker (Kuzu is embedded; keep Neo4j version as `docker-compose.brain.neo4j.yml`) |

---

## Future Considerations

- **Neo4j migration path**: If Kuzu shows instability, the same Graphiti code works with Neo4j. Add `docker/docker-compose.brain.neo4j.yml` + `GRAPHITI_BACKEND=neo4j` env var.
- **Community detection**: Run `graphiti.build_communities()` as a scheduled weekly job (Sunday 02:00 AM). Add to scheduler once Phase 1 is stable.
- **Temporal queries**: `valid_at`/`invalid_at` on every edge enables "what did Aaron believe in January?" queries. Phase 2 power feature.
- **Flutter Brain UI**: Response shape changes from TerminusDB `@id/@type` format to Graphiti `uuid/name/attributes`. Flutter models need updating before Brain UI is built.
- **Curator extension**: Add `write_brain_entity` MCP tool to the Curator agent's mandate (Phase 3 enhancement) — Curator notes entity observations mid-conversation, improving extraction quality.
- **Deduplication tuning**: After first 50 journal imports, review entity quality and iterate on field descriptions in `entities.py`.

---

## References

### Internal References

- Brain module: `computer/modules/brain/module.py`
- Current 14 MCP tools: `computer/modules/brain/mcp_tools.py`
- MCP server tool definitions: `computer/parachute/mcp_server.py:381-572`
- TerminusDB startup (to remove): `computer/parachute/server.py:46-127`, `267-307`
- Daily create_entry hook point: `computer/modules/daily/module.py:87`
- Journal parser: `computer/parachute/mcp_server.py:1094-1135`
- Scheduler infrastructure: `computer/parachute/core/scheduler.py:97-110`
- BrainInterface consumption in Daily: `computer/modules/daily/module.py:41-48`
- Chat log service: `computer/parachute/core/chat_log.py:389`
- Saved queries storage: `vault/.brain/queries.json`

### External References

- Graphiti GitHub: https://github.com/getzep/graphiti
- Graphiti Kuzu support: added late 2025 (`add_episode` with `driver=KuzuDriver`)
- Kuzu Python docs: https://kuzudb.com/docs/client-libraries/python.html
- Graphiti entity types guide: https://help.getzep.com/graphiti/graphiti/entity-types

### Related Work

- TerminusDB MVP plan: `docs/plans/2026-02-22-feat-brain-v2-terminusdb-mvp-plan.md`
- Brain-Graphiti migration brainstorm: `docs/brainstorms/2026-02-25-brain-graphiti-migration-brainstorm.md`
- Curator agent (Chat extraction hook): `docs/brainstorms/2026-02-24-curator-revival-background-context-agent-brainstorm.md`
- MCP session metadata tools: `docs/plans/2026-02-23-feat-mcp-session-metadata-tools-plan.md`
