---
title: "feat: Brain v3 — LadybugDB + agent-driven knowledge graph"
type: feat
date: 2026-02-26
issue: 129
modules: brain, computer, app
priority: P1
status: Phase 1 complete, Phase 2 in progress
---

# feat: Brain v3 — LadybugDB + Agent-Driven Knowledge Graph

## Status

- **Phase 1 (Python backend)** — ✅ Complete. `feat/brain-v3-ladybugdb` branch. Committed, tested, server running v3.0.0.
- **Phase 2 (Flutter UI)** — 🔄 In progress. Next up.
- **Phase 3 (Bridge Agent)** — 📋 Future issue. See `docs/brainstorms/2026-02-27-brain-bridge-agent-brainstorm.md`.

---

## Overview

Replace the Graphiti + Kuzu backend with a lightweight custom graph layer built directly
on LadybugDB (the active Kuzu fork). Remove the LLM extraction pipeline entirely.
Agents write structured knowledge directly to the graph via MCP tools. The Flutter UI
becomes a Tana-style entity browser with inline field editing and a working schema editor.

No external API keys required for Brain operation. No Docker. No extraction pipeline.
Intelligence lives in agent prompts, not in framework machinery.

---

## Background

Phase 1 of issue #128 (Graphiti migration) is committed but superseded. No production
data was ever ingested — clean cutover is safe.

### Why remove Graphiti

- 3–5 LLM calls per `add_episode` for mechanical extraction we can do better with prompts
- Requires `ANTHROPIC_API_KEY` + `GOOGLE_API_KEY` for basic operation
- Entity attributes stored as opaque JSON blob — UI can't display or edit typed fields
- Schema types hardcoded in Python — no hot-reload, no UI schema editor
- Not yet bridged to LadybugDB upstream (graphiti#1132 open, no response)

### Why LadybugDB

LadybugDB (`real_ladybug` on PyPI) is the primary community fork of Kuzu post-Apple
acquisition. Drop-in replacement: `import real_ladybug as kuzu`. Python 3.13 supported
with macOS ARM64 binary wheels. 8 releases since Oct 2025, active cadence.

---

## Technical Approach

### Graph Schema

One node table and one relationship table. Entity attributes are typed columns derived
from `entity_types.yaml` at schema-init time. Hot-reload creates new columns for new
fields; existing data is preserved.

```
Brain_Entity (name STRING PRIMARY KEY, entity_type STRING,
              created_at TIMESTAMP, updated_at TIMESTAMP,
              [field columns from entity_types.yaml...])

Brain_Relationship (FROM Brain_Entity TO Brain_Entity,
                    label STRING, description STRING, created_at TIMESTAMP)
```

Using typed columns (not a JSON blob) means Cypher can filter and sort on any field
directly, and the Flutter UI maps columns to form fields trivially.

**Column management**: When `entity_types.yaml` adds a field, the service runs
`ALTER TABLE Brain_Entity ADD COLUMN field_name STRING DEFAULT NULL`. When a field is
removed, it is ignored in reads (no destructive column drops — data preserved).

### Schema: `vault/.brain/entity_types.yaml`

Hot-reloadable. Loaded fresh on every schema-touching operation (no restart needed).
The server creates this file with defaults on first run if absent.

```yaml
Person:
  occupation: {type: text, description: "Current role or job title"}
  relationship: {type: text, description: "How they relate to you"}
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

All fields are `text` (STRING in LadybugDB Cypher). Richer types (date, integer,
boolean) are a Phase 2 enhancement.

### Search

Phase 1: Cypher substring match on `name` and all text fields. Fast enough for a
personal knowledge graph (hundreds to low thousands of entities).

```cypher
MATCH (e:Brain_Entity)
WHERE e.entity_type = $etype
  AND (toLower(e.name) CONTAINS toLower($q)
    OR toLower(e.occupation) CONTAINS toLower($q))
RETURN e ORDER BY e.updated_at DESC LIMIT $limit
```

Phase 2 (later): Store a `search_text` concatenated column, or add vector embeddings
as a LIST<FLOAT> column for semantic search.

### Agent Write Path

Agents (curator, daily agent, chat agent) call MCP tools directly. No episodes, no
extraction pipeline. Example:

```
brain_upsert_entity(
  entity_type="Person",
  name="Kevin",
  attributes={"occupation": "co-founder", "organization": "Regen Hub"}
)
brain_add_relationship(from_name="Kevin", label="co-owns", to_name="Learn Vibe Build")
```

The agent handles deduplication by calling `brain_get_entity` first. Conflict resolution
is agent judgment. No framework needed.

---

## Implementation Phases

### Phase 1 — Backend (Python)

#### 1.1 — Dependency swap

**`computer/pyproject.toml`**
- Remove: `graphiti-core[anthropic,google-genai]>=0.28.0`, `kuzu>=0.11.0`
- Add: `real-ladybug>=0.14.0`

**`computer/modules/brain/manifest.yaml`**
- Update version: `3.0.0`
- Update description
- Update dependencies

#### 1.2 — Delete obsolete files

- Delete `computer/modules/brain/graphiti_service.py`
- Delete `computer/modules/brain/entities.py`
- Delete `computer/modules/brain/knowledge_graph.py` (already deprecated TerminusDB code)

#### 1.3 — Create `computer/modules/brain/schema.py`

Handles `entity_types.yaml` — load, parse, and generate Cypher DDL.

```python
# schema.py
DEFAULT_ENTITY_TYPES = {
    "Person": {
        "occupation": {"type": "text", "description": "Current role or job title"},
        "relationship": {"type": "text", "description": "How they relate to you"},
        "organization": {"type": "text", "description": "Company or community"},
        "location": {"type": "text", "description": "Where they're based"},
    },
    "Project": { ... },
    "Area": { ... },
    "Topic": { ... },
}

def load_entity_types(vault_path: Path) -> dict:
    """Load entity_types.yaml, creating it with defaults if absent."""

def save_entity_types(vault_path: Path, entity_types: dict) -> None:
    """Write entity_types.yaml atomically."""

def to_api_schema(entity_types: dict) -> list[dict]:
    """Convert to the list[BrainSchemaDetail] shape the Flutter UI expects."""
```

#### 1.4 — Create `computer/modules/brain/ladybug_service.py`

Thin async wrapper around `real_ladybug`. All public methods are async. Writes
serialized via `asyncio.Lock` (LadybugDB is single-writer embedded).

```python
# ladybug_service.py
import real_ladybug as lb
import asyncio
from pathlib import Path

class LadybugService:
    def __init__(self, db_path: Path, vault_path: Path):
        self.db_path = db_path
        self.vault_path = vault_path
        self._db = None
        self._conn = None
        self._write_lock = asyncio.Lock()

    async def connect(self) -> None:
        """Open database and initialize schema."""

    async def close(self) -> None: ...

    # Entity CRUD
    async def upsert_entity(self, entity_type: str, name: str,
                             attributes: dict) -> dict: ...
    async def get_entity(self, name: str) -> dict | None: ...
    async def query_entities(self, entity_type: str, limit: int = 100,
                              offset: int = 0, search: str = "") -> dict: ...
    async def delete_entity(self, name: str) -> bool: ...

    # Schema management
    async def sync_schema(self) -> None:
        """Read entity_types.yaml and ALTER TABLE for any new columns."""

    # Relationships
    async def upsert_relationship(self, from_name: str, label: str,
                                   to_name: str, description: str = "") -> dict: ...
    async def traverse(self, start_name: str, max_depth: int = 2) -> list[dict]: ...

    # Search
    async def search(self, query: str, entity_type: str = "",
                      num_results: int = 20) -> list[dict]: ...

    # Raw Cypher (vault-trust only)
    async def execute_cypher(self, query: str, params: dict = {}) -> list[dict]: ...

    def list_types(self) -> list[dict]:
        """Return schema from entity_types.yaml in BrainSchemaDetail format."""
```

**Schema initialization** (called in `connect()`):

```cypher
CREATE NODE TABLE IF NOT EXISTS Brain_Entity(
    name STRING PRIMARY KEY,
    entity_type STRING,
    created_at TIMESTAMP,
    updated_at TIMESTAMP
)

CREATE REL TABLE IF NOT EXISTS Brain_Relationship(
    FROM Brain_Entity TO Brain_Entity,
    label STRING,
    description STRING,
    created_at TIMESTAMP
)
```

After creating base tables, `sync_schema()` runs `ALTER TABLE Brain_Entity ADD COLUMN`
for every field in `entity_types.yaml` that doesn't already exist.

#### 1.5 — Update `computer/modules/brain/module.py`

- Replace `GraphitiService` with `LadybugService`
- `db_path` = `vault_path / ".brain" / "brain.lbug"`
- Remove `_load_brain_api_keys()` — no API keys needed
- Schema type routes (`POST /types`, `PUT /types/{name}`, `DELETE /types/{name}`)
  now actually work — update `entity_types.yaml` via `schema.py`, call `sync_schema()`
- `POST /episodes` route kept for backward compat — maps to `upsert_entity` with name
  extracted from `name` field and attributes from `episode_body` parsed as JSON or
  stored as `description` field if plain text
- `get_status()` reflects LadybugDB connected state

#### 1.6 — Update `computer/modules/brain/mcp_tools.py`

Update all 17 handlers to call `LadybugService`. Key changes:

| Tool | Old behavior | New behavior |
|------|-------------|--------------|
| `brain_create_type` | Returns 400 | Creates entry in entity_types.yaml + sync_schema() |
| `brain_update_type` | Returns 400 | Updates entry in entity_types.yaml + sync_schema() |
| `brain_delete_type` | Returns 400 | Removes entry from entity_types.yaml (columns preserved) |
| `brain_create_entity` | Synthesizes episode | Direct INSERT to Brain_Entity |
| `brain_update_entity` | Synthesizes update episode | Direct UPDATE on Brain_Entity |
| `brain_delete_entity` | Creates deletion episode | Direct DELETE from Brain_Entity |
| `brain_add_episode` | Graphiti pipeline | Maps to upsert_entity (name from `name` field) |
| `brain_search` | Graphiti hybrid search | Cypher text search across fields |
| `brain_cypher_query` | Raw Kuzu Cypher | Raw LadybugDB Cypher (unchanged) |

#### 1.7 — Remove API key isolation from `claude_sdk.py`

The `sdk_env.pop("ANTHROPIC_API_KEY", None)` guard added in commit `090d769` can be
removed — Brain no longer needs or uses `ANTHROPIC_API_KEY`. Removing the strip is
cleaner than leaving a guard for a no-longer-existent requirement.

#### 1.8 — Update venv

```bash
cd computer
rm -rf .venv
/opt/homebrew/bin/python3.13 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
# Verify:
python -c "import real_ladybug as lb; db = lb.Database('/tmp/test.lbug'); print('OK')"
```

---

### Phase 2 — Flutter UI

#### 2.1 — Update `BrainEntity` model

`brain_entity.dart` currently parses `@id`/`@type` (TerminusDB convention). Update to
parse the new flat response shape:

```dart
// New response shape from GET /api/brain/entities/{type}:
// {
//   "results": [
//     {"name": "Parachute", "entity_type": "Project",
//      "status": "active", "domain": "software", ...}
//   ]
// }

factory BrainEntity.fromJson(Map<String, dynamic> json) {
  final name = json['name'] as String? ?? '';
  final type = json['entity_type'] as String? ?? '';
  final fields = Map<String, dynamic>.from(json)
    ..remove('name')
    ..remove('entity_type')
    ..remove('created_at')
    ..remove('updated_at');
  return BrainEntity(id: name, type: type, fields: fields);
}
```

#### 2.2 — Entity detail inline editing

`brain_entity_detail_screen.dart`: Replace read-only field display with inline editable
text fields. Each field from the schema gets a `TextFormField`. Save on focus-out or
explicit Save button → `PUT /api/brain/entities/{name}`.

#### 2.3 — Entity cards show real fields

`brain_entity_card.dart`: `primaryFields` currently comes from schema definition.
Update to show actual values from `entity.fields` for the first 2–3 non-empty fields.

#### 2.4 — Schema editor now functional

`brain_type_manager_sheet.dart`: The existing UI for creating/editing types was built
for TerminusDB and returned 400 from the backend. With the new `POST/PUT /types`
endpoints working, this sheet now works without Flutter changes.

Add a "delete type" confirmation flow in the sheet (data is preserved, columns remain).

#### 2.5 — Search bar switches to server-side search

`brain_entity_list_screen.dart`: Replace client-side filter with a debounced call to
`POST /api/brain/search`. Keeps the existing 300ms debounce. Passes `entity_type` and
`query` in the request body.

---

### Phase 3 — Bridge Agent (Future Issue)

> Not in scope for this PR. Documented in `docs/brainstorms/2026-02-27-brain-bridge-agent-brainstorm.md`.

The bridge agent is a Haiku pre-hook that runs before the chat agent on every user message. It makes an intent judgment:

- **Enrich** — load relevant brain context when the user is making a request the chat agent will handle but has no reason to query brain directly
- **Step back** — when the user is explicitly asking the chat agent to query the brain, let it do so directly (loading partial context would interfere)
- **Pass through** — normal conversation with no brain involvement needed

Post-turn: bridge evaluates the exchange and writes back significant information (commitments, decisions, new relationships) via `remember` calls. Most turns nothing is written.

This adds a `remember`/`recall` NL interface layer above the current CRUD MCP tools. The CRUD tools remain — they're what the chat agent calls for intentional direct queries and what the bridge internally calls when translating its NL judgments into graph operations.

**Depends on Phase 1+2 being complete and in production.** Will be a separate issue and PR.

---

## Files to Create / Modify / Delete

### New Files

| File | Purpose |
|------|---------|
| `computer/modules/brain/schema.py` | entity_types.yaml load/save/DDL generation |
| `computer/modules/brain/ladybug_service.py` | LadybugDB async wrapper |
| `vault/.brain/entity_types.yaml` | Created at runtime if absent |

### Modified Files

| File | Changes |
|------|---------|
| `computer/modules/brain/module.py` | Swap service, working schema type endpoints |
| `computer/modules/brain/mcp_tools.py` | All 17 handlers updated |
| `computer/modules/brain/manifest.yaml` | Version 3.0.0, updated deps |
| `computer/pyproject.toml` | Swap graphiti-core + kuzu → real-ladybug |
| `computer/parachute/core/claude_sdk.py` | Remove ANTHROPIC_API_KEY strip (no longer needed) |
| `app/lib/features/brain/models/brain_entity.dart` | Parse new flat response shape |
| `app/lib/features/brain/screens/brain_entity_detail_screen.dart` | Inline editing |
| `app/lib/features/brain/widgets/brain_entity_card.dart` | Show actual field values |
| `app/lib/features/brain/screens/brain_entity_list_screen.dart` | Server-side search |

### Deleted Files

| File | Reason |
|------|--------|
| `computer/modules/brain/graphiti_service.py` | Replaced by ladybug_service.py |
| `computer/modules/brain/entities.py` | Replaced by entity_types.yaml |
| `computer/modules/brain/knowledge_graph.py` | Deprecated TerminusDB code |

---

## Acceptance Criteria

### Backend

- [ ] `pip install real-ladybug` succeeds in Python 3.13 venv
- [ ] `parachute server -f` starts with Brain module showing `connected: true`
- [ ] No `ANTHROPIC_API_KEY` or `GOOGLE_API_KEY` required for Brain to function
- [ ] `GET /api/brain/types` returns Person/Project/Area/Topic with their fields
- [ ] `POST /api/brain/types` creates a new entity type in entity_types.yaml
- [ ] `PUT /api/brain/types/{name}` adds/updates fields, no restart needed
- [ ] `POST /api/brain/entities` creates entity directly (no LLM call)
- [ ] `GET /api/brain/entities/{type}` returns entities with typed field values
- [ ] `PUT /api/brain/entities/{name}` updates field values directly
- [ ] `DELETE /api/brain/entities/{name}` removes entity from graph
- [ ] `POST /api/brain/search` returns entities matching text query
- [ ] `POST /api/brain/relationships` creates typed edge between two entities
- [ ] All 17 MCP tools return valid responses (no 500 errors)
- [ ] `brain_create_type` MCP tool creates a new type successfully
- [ ] Concurrent write test: 3 simultaneous upserts do not corrupt the database

### Flutter UI

- [ ] Entity list shows actual field values (not blank cards)
- [ ] Entity detail shows all schema fields with their current values
- [ ] Clicking a field in entity detail opens an inline text editor
- [ ] Saving an edited field updates the entity on the server
- [ ] Schema editor "+ New Type" creates a type that immediately appears in the sidebar
- [ ] Schema editor "Add Field" adds a field to entity_types.yaml and the form updates
- [ ] Entity cards show non-empty field values for the first 2–3 fields
- [ ] Search input hits server-side search (not client-side filter)

### Cleanup

- [ ] No `graphiti-core` or `kuzu` in pyproject.toml
- [ ] `graphiti_service.py`, `entities.py`, `knowledge_graph.py` deleted
- [ ] `ANTHROPIC_API_KEY` strip removed from claude_sdk.py

---

## Risk Notes

**LadybugDB maturity**: 3.5 months old, 10 contributors, 38 open issues. Do a 30-minute
spike first: `pip install real-ladybug`, create a test DB, run basic CRUD and a
traversal query. If anything breaks, fall back to pinned `kuzu==0.11.3` (last stable
release before archiving). The only code change is the import alias.

**ALTER TABLE behaviour**: LadybugDB inherits Kuzu's Cypher DDL. `ADD COLUMN` with
`DEFAULT NULL` is standard Kuzu behaviour. Verify this works for STRING columns during
the spike before committing to the typed-columns schema design.

**Agent prompting**: How agents know what to write to Brain is deliberately out of scope
for this plan. The MCP tools are the write interface; prompt strategy is a separate
system-prompt architecture session.

---

## References

### Internal

- Brainstorm: `docs/brainstorms/2026-02-26-brain-ladybugdb-agent-native-brainstorm.md`
- Replaced plan: `docs/brainstorms/2026-02-25-brain-graphiti-migration-brainstorm.md` (archived)
- Brain module: `computer/modules/brain/module.py`
- Current MCP tools: `computer/modules/brain/mcp_tools.py`
- Flutter Brain service: `app/lib/features/brain/services/brain_service.dart`

### External

- LadybugDB GitHub: https://github.com/LadybugDB/ladybug
- LadybugDB Python docs: https://docs.ladybugdb.com/client-apis/python/
- real-ladybug on PyPI: https://pypi.org/project/real-ladybug/
