---
date: 2026-02-25
topic: brain-graphiti-migration
status: Draft
priority: P1
modules: brain, daily, chat
issue: "#128"
---

# Migrate Parachute Brain to Graphiti

## What We're Building

Replace the Brain module's TerminusDB backend with Graphiti + Kuzu. Alongside this, build the Daily → Brain and Chat → Brain extraction pipelines so the knowledge graph gets dynamically populated from journals and conversations — with no manual data entry required.

The goal is a personal knowledge graph that feels alive: read journals, capture conversations, and the graph builds itself. Aaron writes naturally; the agent translates to structure.

## Context

The Brain module was built Phase 1 MVP-complete on TerminusDB: full CRUD, relationships, traversal, 14 MCP tools, Docker setup, YAML schema compiler. But TerminusDB has no LLM extraction pipeline — to get "journal text → structured entities" working would mean building Graphiti from scratch on top of it.

Graphiti (getzep/graphiti) is purpose-built for exactly this use case: temporal knowledge graph engine over Neo4j, with LLM entity extraction, deduplication, contradiction detection, and hybrid search built in. Research across the Graphiti codebase, GitHub issues, and real-world usage confirms it's the right foundation.

Since there is no production data in TerminusDB yet, a clean cutover is appropriate.

## Why Graphiti: Full Competitive Landscape

Evaluated six frameworks. Four eliminated immediately; one is worth watching later.

| Framework | Verdict | Key reason |
|---|---|---|
| **TerminusDB** | Eliminated | No LLM extraction pipeline — you'd build Graphiti from scratch |
| **Mem0** | Eliminated | No temporal model (overwrites facts, doesn't invalidate them). No typed schemas. It's chatbot session memory, not a knowledge graph. |
| **Microsoft GraphRAG** | Eliminated | Batch-only (re-index when data changes). 13.4% lower accuracy than vanilla RAG on factual queries. Not designed for a growing daily journal. |
| **Letta / MemGPT** | Eliminated | Agent decides what to remember — misses things. No typed schemas, no temporal invalidation. |
| **LangChain / LlamaIndex** | Eliminated | Building blocks, not a solution. No dedup, no temporal. You'd be building Graphiti from scratch. |
| **Cognee** | Watch (6-12 mo) | Richer ontology control, but currently delegates temporal support to Graphiti internally. Earlier-stage (5K vs 14K stars), more complex to operate. |
| **Graphiti** | **Chosen** | Only framework purpose-built for continuous text ingestion + typed entity extraction + bitemporal invalidation + structured views via Cypher. Cited as the reference implementation in February 2026 survey papers. |

**Temporal invalidation is the non-negotiable requirement no other framework meets natively.** When Aaron's focus shifts, when a project goes inactive, when a relationship changes — the Brain must reflect that without losing the history. Mem0 overwrites. GraphRAG re-indexes. Letta relies on the agent noticing. Graphiti tracks it structurally with `valid_at` / `invalid_at` on every edge.

## Why Graphiti Over TerminusDB

| Capability | TerminusDB | Graphiti + Neo4j |
|---|---|---|
| LLM extraction from journal/chat text | Must build from scratch | Built-in |
| Entity deduplication | Must build from scratch | 3-phase pipeline |
| Temporal fact model (valid_at/invalid_at) | Git versioning (wrong fit) | First-class on every edge |
| Contradiction detection | Must build from scratch | Built-in |
| Hybrid search (semantic + BM25) | Must build from scratch | Built-in |
| Structured views | WOQL queries | Direct Cypher |
| Ecosystem | Small, DFRNT maintainers (2025) | Neo4j + 20K-star Graphiti |

TerminusDB's strong schema enforcement would matter if we had a stable, pre-defined ontology. For a personal knowledge graph that evolves with life, Graphiti's dynamic schema (entities emerge from text) is the right trade-off.

## Chosen Approach: Clean Cutover

Remove TerminusDB and replace the Brain module backend with Graphiti + Kuzu in one pass. No production data to migrate. Keep the same 14 MCP tool names so existing Daily and Chat code continues to work. Replace the internal implementation. When the Kuzu fork ecosystem settles on a clear winner, migration is a one-line import swap.

**Why not parallel run:** No production data exists to protect. Dual-backend maintenance would slow everything down with no benefit.

**Why not greenfield module:** The existing module's MCP API surface, FastAPI routes, and module loading infrastructure are all correct and worth keeping. Only the backend changes.

## Key Decisions

- **Database**: **Kuzu (current stable version) for now.** Kuzu was acquired by Apple in October 2025 and archived — no new development — but the last stable release is functional and has no known critical issues. The fork ecosystem (LadybugDB, bighorn, others) is still settling; picking a winner too early risks backing the wrong project. Use Kuzu until a clear community successor emerges, then migrate. Migration is low-risk: all forks are drop-in replacements with the same Cypher API. FalkorDB ruled out (broken Docker image). Neo4j is the fallback if Kuzu's archived state causes a real problem before a fork wins.
- **Migration strategy**: Clean cutover. Rewrite `knowledge_graph.py` and `mcp_tools.py`; keep the module structure and MCP tool names intact.
- **Entity types**: 4 Pydantic types — `Person`, `Project`, `Area`, `Topic`. All fields `Optional` (required by Graphiti's LLM extraction model). Field descriptions serve as the extraction prompt.
- **group_id**: Single group_id per user (`user-{id}`). Journal entries and chat sessions share the same entity space; provenance tracked via `source_description`.
- **YAML schema compiler**: Removed. TerminusDB-specific. Entity types are now defined as Pydantic models in Python code, not YAML.
- **Query model**: Graphiti hybrid search for semantic/open queries. Direct Cypher for deterministic structured views (active projects dashboard, contact cadence, area health).
- **Extraction model**: Claude Sonnet (same model powering the app). Avoid small/local models — structured output reliability drops sharply.
- **Episode ingestion**: `add_episode_bulk` for legacy journal import (~162 files). `add_episode` per entry for ongoing Daily and Chat.
- **Daily→Brain integration**: Fire-and-forget background task in the Daily entry save flow. No curator involvement — Daily owns the event.
- **Chat→Brain integration**: Extend the curator (`curator_mcp.py`) with a `brain_add_episode` tool, or add a separate session-end lifecycle hook. The curator already bridges Chat→Daily via `log_activity`; Brain is a natural extension. Decision on session-end trigger deferred (see Open Questions).
- **Community detection**: Disabled inline (`build_communities=False`) to avoid per-ingestion overhead. Run as a background/scheduled job.

## The 4-Type Schema

```python
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
```

Notes are not a separate type — raw journal entries live as `EpisodicNode` objects (Graphiti's native provenance layer). The entities extracted *from* notes are the typed entities.

## The Pipeline

Two ingest paths, same Graphiti call at each end:

**Daily → Brain** (fire-and-forget hook in the Daily entry save flow):
```
Daily entry saved (POST /entries)
        │
        ▼
background task: brain_ingest_entry(text, date, entry_id)
        │
        ▼
graphiti.add_episode(
    name="Journal 2026-02-25 {entry_id}",
    episode_body=entry_text,
    source=EpisodeType.text,
    source_description="Daily journal 2026-02-25",
    reference_time=entry_timestamp,
    entity_types={"Person": Person, "Project": Project, "Area": Area, "Topic": Topic},
    group_id="user-aaron",
    build_communities=False
)
        │
        ▼
Graphiti (internal): Claude Sonnet extracts entities → Person/Project/Area/Topic nodes
Deduplication → same entity across sources resolves to one node
Temporal edges → RELATES_TO with valid_at/invalid_at
```

**Chat → Brain** (via the curator background agent or a session-end hook):
```
Chat session closes (or session-end lifecycle event)
        │
        ▼
brain_add_episode(full_transcript, session_id)
        │
        ▼
graphiti.add_episode(
    name="Chat session {session_id}",
    episode_body=full_transcript,
    source=EpisodeType.text,
    source_description="Chat session {session_id}",
    reference_time=session_created_at,
    entity_types={...},
    group_id="user-aaron",
    build_communities=False
)
```

The curator (Claude Haiku, fire-and-forget per-exchange agent) is the natural extension point for Chat→Brain: it already bridges Chat and Daily via `log_activity` → `vault/Daily/.activity/{today}.jsonl`. It has `session_id` and `vault_path` baked in per run. A new `brain_add_episode` MCP tool in `curator_mcp.py` would fetch the full session transcript and call Brain's MCP. The curator itself doesn't do entity extraction — Graphiti handles that internally via Claude Sonnet. Note: the curator fires at exchange cadence ({1,3,5} then every 10th), not at session end — see Open Questions.

## Key Views (Cypher)

```cypher
-- Active projects
MATCH (p:Entity:Project)
WHERE p.group_id = $group_id AND p.attributes.status = 'active'
RETURN p.name, p.summary, p.attributes

-- People not mentioned in 30 days
MATCH (person:Entity:Person) WHERE person.group_id = $group_id
OPTIONAL MATCH (e:Episodic)-[:MENTIONS]->(person)
WHERE e.created_at > datetime() - duration({days: 30})
WITH person, count(e) AS recent_mentions
WHERE recent_mentions = 0
RETURN person.name, person.summary

-- Currently valid facts about a person
MATCH (p:Entity {name: $name})-[r:RELATES_TO]-(other:Entity)
WHERE p.group_id = $group_id AND r.invalid_at IS NULL
RETURN r.fact, other.name, r.valid_at ORDER BY r.created_at DESC
```

## Open Questions

- **MCP tool surface**: Keep all 14 existing tool names? Or rationalize/add new ones (e.g., `brain_add_episode`, `brain_cypher_query`)?
- **Saved queries**: The existing `brain_save_query` / `brain_list_saved_queries` tools persist named filter queries. How do these translate? Store as named Cypher strings?
- **Legacy import**: Should the bulk journal import be triggered automatically on first Brain startup, or manually via a one-shot script?
- **Deduplication quality**: Field descriptions are the extraction prompt — how much tuning will field descriptions need after seeing real extraction results?
- **Kuzu fork landscape**: Four forks emerged post-archival. LadybugDB (506 stars, 7 releases in 10 weeks, dropped CLA, active feature development) is the current frontrunner. RyuGraph by Predictable Labs (ex-Dgraph CEO Akon Dey, 3 monthly releases) is a credible #2. Bighorn (Kineviz/GraphXR) has corporate backing but zero public releases — internal-only. GraphLite is a Rust rewrite with ISO GQL (not Cypher) — too early, not a drop-in. No clear winner declared as of Feb 2026. The single most important signal: whether Graphiti files a PR supporting LadybugDB (track getzep/graphiti#1132 — zero response after 2 months). When a winner is clear, migration is a one-line import swap.
- **Neo4j fallback**: If Kuzu's archived state causes a real problem before a fork wins (e.g. a security CVE, Python version incompatibility), Neo4j is the fallback. Same Cypher queries, minimal code change.
- **Chat→Brain session-end trigger**: The curator fires at exchange cadence ({1,3,5} then every 10th) — not at session end. A chat could close without triggering a curator run. Options: (a) extend curator cadence with a session-end hook, (b) add a separate `brain_harvester` called from the Chat session close path, (c) ingest incrementally every N exchanges regardless of session end. Which is the right trigger?
- **Curator model for Brain calls**: The curator uses Claude Haiku. Graphiti entity extraction uses Claude Sonnet (configured internally). These are independent — the curator just passes text to Brain's MCP. No model conflict, but worth confirming Graphiti's model config is set correctly.
- **Flutter UI**: Phase 2 plans a Flutter Brain UI. Does the API shape change enough to matter for those plans?

## Next Steps

→ `/para-plan` for the implementation plan
