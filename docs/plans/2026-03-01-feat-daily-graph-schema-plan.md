---
title: Daily module graph schema — Phase 2
type: feat
date: 2026-03-01
issue: 157
---

# Daily module graph schema (Phase 2)

Phase 2 of the SQLite thinning arc. The Chat module (Phase 1) now writes exchanges directly to the graph. This phase does the same for the Daily module: journal entries get their own `Journal_Entry` and `Day` node types, registered by `DailyModule.on_load()` and written on create.

The markdown files in `vault/Daily/entries/` remain the source of truth — the graph is a queryable index, not a replacement.

## Problem Statement

- Daily journal entries exist only as markdown files; no graph representation
- Can't traverse "what Brain entities appeared in entries this week" across modules
- `create_entry()` is sync — hard to extend with async concerns (graph writes, future enrichment)

## Proposed Solution

### Schema

Two node types + one relationship:

```
Journal_Entry
  entry_id   STRING  (PK) — "2026-03-01-14-30"
  date       STRING        — "2026-03-01"
  content    STRING        — full text
  snippet    STRING        — first 200 chars
  created_at STRING        — ISO timestamp

Day
  date       STRING  (PK) — "2026-03-01"
  created_at STRING        — ISO timestamp of first entry

HAS_ENTRY: Day → Journal_Entry
```

`Day` groups entries for calendar traversal ("show all entries from March 1").
`Journal_Entry.content` enables cross-module text search without re-reading files.

### Write path

`create_entry()` → becomes `async def create_entry()`

After writing the markdown file:
1. `MERGE (d:Day {date: $date}) ON CREATE SET d.created_at = $now`
2. `MERGE (e:Journal_Entry {entry_id: $entry_id}) ON CREATE SET e.created_at = $now SET e.date, e.content, e.snippet`
3. `MATCH (d:Day), (e:Journal_Entry) MERGE (d)-[:HAS_ENTRY]->(e)`

All three writes inside `async with graph.write_lock`.

### Module changes

**`DailyModule.on_load()`** — new async hook (same pattern as `ChatModule.on_load()`):
```python
async def on_load(self) -> None:
    graph = get_registry().get("GraphDB")
    await graph.ensure_node_table("Journal_Entry", {...}, primary_key="entry_id")
    await graph.ensure_node_table("Day", {"date": "STRING", "created_at": "STRING"}, primary_key="date")
    await graph.ensure_rel_table("HAS_ENTRY", "Day", "Journal_Entry")
```

**`create_entry()`** → `async def create_entry()` — add graph write after file write (fire-and-forget safe: if GraphDB not in registry, skip silently).

**FastAPI route** — `async def create_entry(body)` already async, just `await self.create_entry(...)`.

## Acceptance Criteria

- [x] `DailyModule.on_load()` registers `Journal_Entry`, `Day`, `HAS_ENTRY` in shared GraphDB
- [x] `create_entry()` is async and writes `Journal_Entry` + `Day` + `HAS_ENTRY` to graph on every new entry
- [x] Graph writes are skipped silently if GraphDB is not in registry (no crash)
- [x] Markdown files remain the canonical source of truth (no reads from graph)
- [x] `ON CREATE SET` protects `created_at` on both node types (idempotent merges)
- [x] All 489 unit tests pass

## Out of Scope

- Backfilling existing markdown entries to the graph (Phase 3 operational data, separate issue)
- Updating the graph when entries are edited (entries are append-only for now)
- `list_entries()` / `get_entry()` reading from graph instead of files (Phase 4)

## File Changes

| File | Change |
|------|--------|
| `computer/modules/daily/module.py` | Add `on_load()`, make `create_entry()` async, add graph write |

One file. No new files needed.

## References

- Phase 0: PR #154 (GraphService core infrastructure, merged)
- Phase 1: PR #156 (Chat graph schema, merged)
- Chat module for `on_load()` pattern: `computer/modules/chat/module.py`
- Bridge agent for graph write pattern: `computer/parachute/core/bridge_agent.py`
