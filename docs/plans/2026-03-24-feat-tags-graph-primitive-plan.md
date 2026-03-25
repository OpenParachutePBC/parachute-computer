---
title: Tags as a first-class graph primitive
type: feat
date: 2026-03-24
issue: 321
---

# Tags as a First-Class Graph Primitive

## Overview

Replace the JSON-array tag storage on Chat nodes and journal entry metadata with a graph-native `Tag` node type and `TAGGED_WITH` relationship. Any node in the brain graph becomes taggable via a single relationship edge, enabling cross-entity queries ("show me everything tagged #parachute") and consistent tag management across Chats, Notes, Cards, Brain entities, and Agents.

## Problem Statement

Tags exist in two disconnected stores today:
- **Chat sessions**: `tags_json` column (JSON string array) on Chat nodes, with full CRUD API
- **Journal entries**: nested inside `Note.metadata_json['tags']`, with Flutter UI but no dedicated API

Both implementations scan ALL nodes and filter in Python (no Cypher-side filtering). Cross-entity tag queries are impossible without application-level joins. Adding tags to new entity types (Cards, Brain entities) would require duplicating the JSON-array pattern each time.

## Proposed Solution

### Phase 1: Graph Schema + Core Tag Service

Create the `Tag` node table and `TAGGED_WITH` relationship table, plus a `TagService` with methods for tag CRUD that work across any entity type.

**Tag node table:**
```python
await graph.ensure_node_table("Tag", {
    "name": "STRING",           # PK — lowercase, normalized
    "description": "STRING",    # optional
    "created_at": "STRING",     # ISO timestamp
}, primary_key="name")
```

**TAGGED_WITH relationship table:**

Kuzu 0.8.0+ unified `CREATE REL TABLE` supports multiple FROM/TO pairs (the old `GROUP` keyword is deprecated). Use raw DDL since `ensure_rel_table` only handles single FROM/TO:

```python
CREATE REL TABLE IF NOT EXISTS TAGGED_WITH (
    FROM Chat TO Tag,
    FROM Note TO Tag,
    FROM Card TO Tag,
    FROM Brain_Entity TO Tag,
    FROM Agent TO Tag,
    tagged_at STRING,
    tagged_by STRING
)
```

Add an `ensure_rel_table_multi` helper to `BrainService` for this pattern, or just execute the DDL directly in schema setup.

**TagService** (new class or methods on BrainChatStore):

```python
async def add_tag(entity_table: str, entity_pk_col: str, entity_id: str, tag: str, tagged_by: str = "user") -> None
async def remove_tag(entity_table: str, entity_pk_col: str, entity_id: str, tag: str) -> None
async def get_entity_tags(entity_table: str, entity_pk_col: str, entity_id: str) -> list[str]
async def get_entities_by_tag(tag: str, entity_type: str | None = None, limit: int = 100) -> list[dict]
async def list_all_tags() -> list[dict]  # {name, count, description}
async def delete_orphan_tags() -> int     # cleanup tags with zero relationships
```

**Tag validation:** `[a-z0-9][a-z0-9\-]{0,47}` — lowercase alphanumeric with hyphens, max 48 chars. Normalized on write (`tag.lower().strip()`).

**Files:**
- `computer/parachute/db/brain.py` — add `ensure_rel_table_multi()` or raw DDL execution
- `computer/parachute/db/brain_chat_store.py` — add Tag node table to schema setup, add TAGGED_WITH rel table, implement TagService methods (can be methods on BrainChatStore or a separate mixin)

### Phase 2: Universal Tag API Endpoints

Replace the chat-specific tag endpoints in `sessions.py` with universal endpoints on a new `tags.py` router.

**New endpoints:**
| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/tags` | List all tags with usage counts |
| `GET` | `/api/tags/{tag}` | Get all entities with this tag (cross-type, with optional `?type=` filter) |
| `POST` | `/api/tags/{entity_type}/{entity_id}` | Add tag to any entity |
| `DELETE` | `/api/tags/{entity_type}/{entity_id}/{tag}` | Remove tag from entity |
| `GET` | `/api/tags/{entity_type}/{entity_id}` | List tags for an entity |

`entity_type` maps to graph node tables: `chat` -> Chat, `note` -> Note, `card` -> Card, `entity` -> Brain_Entity, `agent` -> Agent. Each type has its own primary key column name (session_id, entry_id, card_id, name, name).

**Backward compatibility:** Keep the old `/chat/{session_id}/tags` endpoints temporarily as thin wrappers that delegate to the new TagService. Mark as deprecated. Remove in a future release.

**Files:**
- `computer/parachute/api/tags.py` — new router
- `computer/parachute/api/sessions.py` — deprecate tag endpoints, delegate to TagService
- `computer/parachute/server.py` — mount new tags router

### Phase 3: Migration

Migrate existing tag data from JSON arrays to graph edges, then remove the old storage.

**Chat tags migration:**
1. Query all Chat nodes with non-empty `tags_json`
2. For each tag string, MERGE a Tag node, CREATE a TAGGED_WITH edge
3. After migration, drop `tags_json` column (or clear it and leave the column for schema compat)

**Journal entry tags migration:**
1. Query all Note nodes with non-empty `metadata_json`
2. Parse JSON, extract `tags` array if present
3. For each tag, MERGE Tag node, CREATE TAGGED_WITH edge
4. Remove `tags` key from `metadata_json` and write back

**Migration runs automatically** on server startup (idempotent — checks if TAGGED_WITH edges already exist before migrating). Add a `_migrate_tags_to_graph()` method called during `BrainChatStore.initialize()`.

**Files:**
- `computer/parachute/db/brain_chat_store.py` — migration logic in `initialize()` or a dedicated `_migrate_tags()` method

### Phase 4: Update MCP Tools

The Parachute MCP tools exposed to agents need tag operations. Update the vault tools to use the new TagService.

**Existing tools to update:**
- `search_by_tag` — currently not in VAULT_TOOLS (only in the Parachute SDK session tools). If it exists in the session API MCP bridge, update to use TagService.
- `add_session_tag` / `remove_session_tag` — same.
- `list_tags` — same.

**New tool (optional v1):**
- `tag_entity` — allow agents to tag any entity type (not just chat sessions)

**Files:**
- `computer/parachute/core/vault_tools.py` — update or add tag tools
- `computer/parachute/api/mcp_tools.py` — update MCP bridge handlers if tag tools exist there

### Phase 5: Flutter UI

Extend the existing journal tag UI pattern to other entity types and add tag autocomplete.

**Tag autocomplete widget:** Extract a reusable `TagInput` widget from `entry_edit_modal.dart` that:
- Shows tag chips with delete
- Has a text field with autocomplete (fetches from `GET /api/tags`)
- Calls add/remove tag API on change

**Apply to:**
- Journal entries (replace inline tag UI in `entry_edit_modal.dart`)
- Chat sessions (new — add tag chips to session info/settings)
- Cards (new — add tag chips to card detail/header)

**API service:**
- Add `TagApiService` or extend `DailyApiService` with universal tag methods

**Files:**
- `app/lib/shared/widgets/tag_input.dart` — new reusable widget
- `app/lib/shared/services/tag_api_service.dart` — new API service
- `app/lib/features/daily/journal/widgets/entry_edit_modal.dart` — refactor to use TagInput
- `app/lib/features/chat/` — add tag UI to session info (stretch goal)

## Technical Considerations

- **Kuzu REL TABLE multi-source**: Kuzu 0.8.0+ supports `CREATE REL TABLE` with multiple FROM/TO pairs. LadybugDB 0.14.1 wraps a compatible Kuzu version. Need to verify this works with `IF NOT EXISTS` — if not, use try/except.
- **Primary key column names vary**: Chat uses `session_id`, Note uses `entry_id`, Card uses `card_id`, Brain_Entity and Agent use `name`. The TagService needs a mapping from entity_type string to (table_name, pk_column).
- **Orphan cleanup**: When removing the last TAGGED_WITH edge for a tag, auto-delete the Tag node. Run cleanup in `remove_tag()` or as a periodic task.
- **Brain_Entity table may not exist**: It's created by the brain module, which may not be initialized. Guard with try/except in TAGGED_WITH table creation.
- **`tags_json` column removal**: Kuzu may not support `ALTER TABLE DROP COLUMN`. If not, just clear the values to empty `[]` and leave the column. Document as deprecated.

## Acceptance Criteria

- [x] `Tag` node table exists in the brain graph with `name` (PK), `description`, `created_at`
- [x] `TAGGED_WITH` relationship table connects Chat, Note, Card, Brain_Entity, Agent to Tag
- [x] Universal tag API: add, remove, list tags for any entity type
- [x] Cross-entity tag query: `GET /api/tags/{tag}` returns entities of all types
- [x] `GET /api/tags` returns all tags with usage counts
- [x] Existing Chat `tags_json` data migrated to graph edges on startup
- [x] Existing journal entry metadata tags migrated to graph edges on startup
- [x] Old chat tag API endpoints still work (backward compat, delegating to new service)
- [x] Tag validation: lowercase alphanumeric + hyphens, max 48 chars
- [x] Orphan tags auto-deleted when last relationship removed
- [x] Reusable `TagInput` Flutter widget with autocomplete
- [x] Journal entry edit modal uses new `TagInput` widget
- [x] MCP tools updated to use graph-native tags
- [x] Tests pass (`make test-fast`) — pre-existing test_date_filter failure unrelated

## Dependencies & Risks

- **LadybugDB multi-FROM/TO support**: Untested in this codebase. If it doesn't work, fall back to separate rel tables per source type (`Chat_TAGGED_WITH`, `Note_TAGGED_WITH`, etc.) — uglier queries but guaranteed to work.
- **Migration idempotency**: Must be safe to run multiple times (use MERGE for Tag nodes, check for existing edges before creating).
- **Column drop support**: Kuzu may not support dropping columns. Plan for leaving `tags_json` as a deprecated empty column.

## References

- Brainstorm: `docs/brainstorms/2026-03-24-tags-graph-primitive-brainstorm.md`
- Current tag code: `computer/parachute/db/brain_chat_store.py` lines 1084-1158
- Current tag API: `computer/parachute/api/sessions.py` lines 119-160, 506-557
- Flutter tag UI: `app/lib/features/daily/journal/widgets/entry_edit_modal.dart` lines 595-684
- Graph schema helpers: `computer/parachute/db/brain.py` lines 167-242
- Kuzu CREATE REL TABLE docs: https://docs.kuzudb.com/cypher/data-definition/create-table/
