---
title: Tags as a first-class graph primitive
status: brainstorm
priority: P2
issue: 321
date: 2026-03-24
---

# Tags as a First-Class Graph Primitive

## What We're Building

A unified, graph-native tagging system where `Tag` is a node type and `TAGGED_WITH` is a relationship type. Any node in the brain graph can be tagged, enabling cross-entity queries like "show me everything tagged #parachute" — spanning chats, journal entries, cards, and brain entities in a single traversal.

Tags are connective tissue across the whole system, not per-entity metadata.

## Why This Approach

**Graph-native over JSON arrays** because:
- Cross-entity queries are a single Cypher traversal (`MATCH (t:Tag {name: $tag})<-[:TAGGED_WITH]-(n) RETURN n`)
- No need to enumerate taggable types — any node can have a `TAGGED_WITH` edge
- Tags themselves become queryable entities (description, created_at, usage patterns)
- Consistent with the open-ontology philosophy of the brain graph

The alternative (extending JSON arrays to more entity types) was rejected because it fragments tag data across tables and makes cross-entity queries impossible without application-level joins.

## Key Decisions

### Taggable Entities
Everything that's a node in the graph, **except Messages** (individual chat exchanges). Starting set:
- **Chat** sessions (migrated from `tags_json`)
- **Journal entries / Notes** (migrated from entry metadata)
- **Cards** (new)
- **Brain_Entity** nodes (new)
- **Agents** (new)

Messages were excluded as tagging at that level feels more like highlighting/annotation. Easy to add later since the pattern is the same.

### Who Creates Tags
- **Users** — primary taggers, via UI (tag chips, autocomplete)
- **Agents** — can add tags to any entity (e.g., process-day auto-tags by topic)
- No complex permission model. Any agent can tag anything — trust boundaries are at the sandbox level, not the tag level.

### Tag Schema
```
Tag node:
  - name (PK, STRING) — lowercase, normalized
  - description (STRING, optional) — what this tag represents
  - created_at (STRING) — ISO timestamp

TAGGED_WITH relationship:
  - tagged_at (STRING) — ISO timestamp
  - tagged_by (STRING) — "user" or agent name
```

### Migration Strategy
Fully migrate to graph — drop `tags_json` after migration, no denormalized cache.

1. Create `Tag` node table and `TAGGED_WITH` relationship table
2. Migrate Chat `tags_json` — read existing arrays, create Tag nodes + edges, then drop the column
3. Migrate Journal entry metadata tags — read from entry meta, create edges
4. Rewrite API — single set of tag endpoints that work across entity types, replacing chat-specific ones
5. Update MCP tools (search_by_tag, add_session_tag, list_tags) to use graph queries

### API Surface
Universal tag endpoints (not per-entity-type):
- `GET /api/tags` — list all tags with counts
- `GET /api/tags/{tag}` — get all entities with this tag (cross-type)
- `POST /api/{entity_type}/{entity_id}/tags` — add tag to any entity
- `DELETE /api/{entity_type}/{entity_id}/tags/{tag}` — remove tag
- `GET /api/{entity_type}/{entity_id}/tags` — list tags for an entity

### UI Patterns
- Tag chips on notes, cards, chat sessions
- Tag autocomplete from existing tags
- Tag filtering in list views
- Cross-entity tag view (everything with tag X)

## Open Questions

- **Tag namespaces**: Should agent-created tags be visually distinct (e.g., `#system:topic` vs `#parachute`)? Leaning no for now — keep it flat.
- **Tag deletion**: When a tag has zero relationships, auto-delete or keep as empty node? Leaning auto-delete (orphan cleanup).
- **Tag merging**: Rename/merge support (e.g., combine `#dev` and `#development`)? Nice to have, not v1.

## Scope

- Module labels: `brain`, `daily`, `app`, `computer`
- Touches: graph schema, BrainChatStore, daily module API, MCP tools, Flutter UI
