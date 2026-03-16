# Issue #269 Brainstorm: Note Organization via Tags + Graph

## Executive Summary

We have event-driven Callers (PR #279) that enable triggered actions on scoped entities. Tags are a natural scoping mechanism to unlock powerful automations: "run agent X only on 'recipe' entries," "aggregate 'project-updates' into a weekly summary," etc.

The system already has:
- Note nodes with `metadata_json` field for flexible storage
- Triggered Callers with `trigger_filter` supporting tags matching
- Auto-tagger Caller template ready to deploy
- Entry-scoped tools (`update_entry_tags`) for tag manipulation

This brainstorm explores: **minimal implementation → effective containment → advanced graph features**.

---

## 1. Tagging Primitive: MVP Design

### 1.1 Where Tags Live (Current State)

**Already implemented:**
- Tags stored in Note's `metadata_json` blob
- Retrieved by `read_entry` tool with metadata unpacking
- Set via `update_entry_tags` triggered Caller tool
- Passed to CallerDispatcher via entry_meta dict for filter matching

```python
# metadata_json: {"tags": ["recipe", "dessert", "quick"], "duration_seconds": 300}
# entry_meta passed to dispatch(): {"tags": ["recipe", "dessert", "quick"], ...}
```

### 1.2 Quick Win: UI Tag Picker (Client-Side)

**Minimal implementation for v1:**

1. **No new server/graph columns needed** — use existing metadata_json
2. **Client (Flutter) adds:**
   - Read `tags` from entry.metadata.tags
   - Show tag pill UI in entry editor
   - Allow add/remove/create-new workflows
   - PATCH entry with updated metadata: `{"metadata": {"tags": ["new", "tags"]}}`
3. **Server continues:** Merge tags into metadata_json, dispatch to Callers

**Pros:**
- Zero graph schema changes
- Works with existing triggered Callers
- Tags appear in entry detail, searchable
- Client can seed common tags (project, recipe, personal, etc.)

**Cons:**
- Tags only exist as strings in entry metadata
- No graph relationships for querying "all entries with tag X"
- Can't do graph traversal (tag → entry → brain concept)

### 1.3 Hashtag Parsing (Optional Layer)

**Use case:** User writes "#recipe" in content, auto-extract as tag.

```python
# In a hashtag-extraction Caller triggered on note.created:
content = "Made chocolate cookies #recipe #dessert"
tags = re.findall(r'#(\w+)', content)
# → ["recipe", "dessert"]
update_entry_tags(tags)
```

**Decision point:**
- Start with explicit picker (MVP)
- Add hashtag extraction as optional enhancement (follows Brain tagging patterns)
- **Both can coexist:** hashtags auto-extracted → merged with explicit tags

### 1.4 AI-Suggested Tags (Auto-Tagger Caller)

**Already templated in module.py:**

```yaml
"name": "auto-tagger",
"trigger_event": "note.created",
"trigger_filter": "{}",  # all entries
"system_prompt": "Assign 1-5 tags per entry...",
"tools": ["read_entry", "update_entry_tags"],
```

**Workflow:**
1. User creates entry
2. `note.created` event fires
3. CallerDispatcher finds enabled auto-tagger
4. Caller reads entry, proposes tags, calls `update_entry_tags`

**Design choice:** Auto-tagger runs **by default on every entry**, user can disable in settings.

---

## 2. Graph Integration Strategy

### 2.1 Option A: Metadata-Only (MVP)

**Current:** Tags live in Note.metadata_json only.

```json
{
  "tags": ["recipe", "dessert"],
  "duration_seconds": 300,
  "transcription_status": "complete"
}
```

**Graph queries still work:**
```cypher
MATCH (e:Note) WHERE e.date = "2025-03-16"
RETURN e.content, e.metadata_json
# Client parses metadata_json to extract tags
```

**Tradeoff:** Flexible but queries can't filter by tag at DB level.

### 2.2 Option B: Denormalized Tag Column (Fast Queries)

**Schema change:** Add `tags_json` column to Note table.

```python
# On_load migration:
await graph.ensure_node_table("Note", {
    "entry_id": "STRING",
    # ... existing columns ...
    "tags_json": "STRING",  # JSON array: ["recipe", "dessert"]
})
```

**Indexing potential:** Kuzu could index tag membership (if needed for performance).

**Update flow:**
- `update_entry_tags` tool updates both metadata_json (for app state) and tags_json (for queries)
- Queries can now filter efficiently:
  ```cypher
  MATCH (e:Note) WHERE e.date = "2025-03-16" AND e.tags_json CONTAINS "recipe"
  RETURN e
  ```

**Tradeoff:** Slight redundancy but unlocks efficient filtering and future indexing.

### 2.3 Option C: First-Class Tag Entities (Graph-Native)

**Schema:**
```cypher
CREATE (t:Tag {name: "recipe"})
CREATE (e:Note {entry_id: "..."})
CREATE (e)-[:TAGGED_WITH]->(t)
```

**Pros:**
- Tag nodes can have metadata (color, description, icon)
- Query "all entries tagged recipe" easily
- Can create aggregations/tag detail screens
- Supports tag hierarchies ("cooking" → "recipe")

**Cons:**
- More schema complexity
- Requires migration script (add Tag nodes, create relationships)
- Callers need new `link_to_tag` tool alongside `update_entry_tags`
- Relationship cardinality: 1 entry × N tags = O(N²) edges long-term

**Recommendation:** Reserve for Phase 2. MVP uses options A or B.

---

## 3. UI Surfaces: Where Tags Appear

### 3.1 Entry Detail View (Must Have)

**Current Flutter entry editor shows:**
- content
- title
- audio_path

**Add:**
- Tags section with pill UI
- Add/remove/create workflows
- Search/filter by tag

### 3.2 Tag Sidebar / Tag Index (Phase 2)

**Post-MVP:**
- List all tags used in vault (with counts)
- Click tag → filter entries view
- Show tag metadata (optional: color, description)

### 3.3 Tag Search / Advanced Filter (Phase 2)

**Current:** List entries by date.

**Future:**
- Filter by tag: "show entries tagged 'meeting'"
- Multi-tag AND/OR: "show 'project' AND 'urgent'"
- Tag + date range: "recipes created in March"

### 3.4 Tag Graph Visualization (Phase 3)

**Depends on first-class Tag nodes (Option C):**
- Force-directed graph: tags as nodes, entries as edges
- Shows tag popularity, entry clusters
- Interesting but lower priority

---

## 4. Effective Containment: Scoping Callers via Tags

### 4.1 Current Trigger Filter Semantics

**From caller_dispatch.py:**

```python
trigger_filter = {"entry_type": "voice", "tags": ["meeting"]}

# Matches if:
# - entry_type == "voice" AND
# - tags contains at least one of ["meeting"]
```

**Filter matching rules:**
- `{}` → always matches
- `{"entry_type": "voice"}` → entry.metadata.type must equal "voice"
- `{"tags": ["meeting"]}` → entry.metadata.tags must have at least one matching tag
- Multiple keys → AND logic (all must match)

### 4.2 Use Cases: Tag-Scoped Callers

**Example 1: Transcription Cleanup (Current)**
```python
trigger_event: "note.transcription_complete"
trigger_filter: {"entry_type": "voice"}
```

**Example 2: Recipe Processing (MVP)**
```python
trigger_event: "note.created"
trigger_filter: {"tags": ["recipe"]}
# Caller extracts ingredients, instructions, duration
# Stores in metadata: {"ingredients": [...], "time_minutes": 45}
```

**Example 3: Meeting Notes (MVP)**
```python
trigger_event: "note.created"
trigger_filter: {"tags": ["meeting"]}
# Caller extracts action items, attendees, decisions
# Stores in metadata: {"action_items": [...], "attendees": [...]}
```

**Example 4: Daily Digest (Scheduled Caller + Tag Filter)**
```python
schedule_enabled: true
schedule_time: "21:00"
trigger_filter: {"tags": ["project-update"]}
# System runs nightly, aggregates entries tagged "project-update"
# Uses read_journal + read_recent_journals to find tagged entries
```

### 4.3 Effective Containment Pattern

**Key insight:** Tags define the boundary of Caller execution.

```
Entry created → Event fires → CallerDispatcher filters by trigger_filter
                                 ↓
                        Match tags? YES → run Caller
                        Match tags? NO  → skip
```

**This enables:**
1. **Semantic scoping:** "only tag AI articles for linking to brain"
2. **Domain isolation:** "recipe Caller shouldn't touch project notes"
3. **Progressive tagging:** User can selectively enable workflows per tag
4. **Cheap filtering:** No graph traversal needed—metadata_json lives on entry

---

## 5. Interaction with Brain Module (v3 - LadybugDB)

### 5.1 Current State

**Brain entities:** Stored as Brain_Entity nodes in LadybugDB.
- `name` (PK)
- `entity_type` (e.g., "Recipe", "Project")
- `description`, metadata columns
- Relationships: MENTIONS, RELATED_TO, etc.

**Brain links:** Stored in Note.brain_links_json (JSON array of entity names).

### 5.2 Design: Tags ≠ Brain Entity Types (Separate Concerns)

**Tags:** Organizational boundaries for Callers and UI filtering.
```
"recipe", "meeting", "personal", "urgent" → informal user labels
```

**Brain entities:** Semantic/knowledge objects.
```
"Recipe" (type) → linked to note if documented recipe
"Project" (type) → linked to note if it's a project page
```

**Independence:** An entry can be tagged "recipe" without creating a Recipe entity.

### 5.3 Pattern: Tag → Entity Type Materialization (Optional)

**Use case:** User tags entry "recipe" regularly. Eventually they want a "recipes" collection in Brain.

**Flow:**
1. Create Recipe entity type in entity_types.yaml (manual or via UI)
2. Create a Caller: `tag_to_entity` (triggered on note.created with tag="recipe")
   ```python
   # Caller logic:
   # - If entry has tag "recipe"
   # - Check if Recipe entity exists
   # - If not, create Recipe in Brain with entry content as description
   # - Link entry to Recipe
   ```

**Result:** Tags seed entity discovery, but entities are explicit.

### 5.4 Querying: Tag + Brain

**Question:** "Show all entries tagged 'recipe' that link to a Recipe entity"

```cypher
# Kuzu query
MATCH (e:Note)
WHERE e.date = "2025-03-16"
  AND e.tags_json CONTAINS "recipe"
RETURN e.content, e.brain_links_json
# Client then queries LadybugDB for entities named in brain_links_json
```

**Advanced (Phase 2):** Cross-database join query via Brain module API.

---

## 6. Architecture Decisions

### 6.1 Where Tags Update

**Current flow:**
1. User edits entry via Flutter
2. PATCH /daily/entries/{id} with metadata
3. Server merges into metadata_json
4. Triggered Callers can read/modify via tools

**Add tagging Caller:**
1. Same PATCH endpoint used
2. Callers with `update_entry_tags` tool can auto-tag
3. No special endpoint needed

### 6.2 Tag Validation & Constraints

**Design principle:** Open tagging (no pre-defined list).

**Optional safeguards:**
- Client suggests common tags (project, recipe, personal, urgent, etc.)
- Server could enforce lowercase + hyphenated (e.g., "project-update" not "Project Update")
- Regex validation: `^[a-z0-9\-]+$`

### 6.3 Tag Lifecycle

**Creation:** Implicit when tag added to entry.
**Deletion:** No explicit tag node—orphaned tags disappear when last entry loses tag.
**Merging:** Manual (rename all entries' tags).

**Future (Option C with Tag nodes):** Could support explicit tag management.

---

## 7. Staged Implementation Plan

### Phase 1: MVP Tag Basics (Weeks 1-2)

**Goal:** Tags in UI, functional Callers can scope by tag.

**Tasks:**
1. **Client (Flutter):**
   - Read tags from entry.metadata.tags
   - Show tag pills in entry editor
   - Add/remove tag UI
   - PATCH entry with updated tags

2. **Server/Graph (Optional, but recommended):**
   - Add `tags_json` column to Note table
   - Update `_write_to_graph()` to populate both metadata_json and tags_json
   - Update CallerDispatcher to read tags from entry_meta (already supported)

3. **Callers:**
   - Deploy auto-tagger template
   - Optional: create 1-2 demo tag-scoped Callers (e.g., recipe, meeting)

**Success criteria:**
- Entries can be manually tagged in UI
- Auto-tagger fires on note.created and suggests tags
- Triggered Callers can filter by tag (already implemented)
- Tag filtering works in entry list (client-side filtering for MVP)

### Phase 2: Tag Indexing & Querying (Weeks 3-4)

**Goal:** Server-side tag filtering, tag sidebar, advanced search.

**Tasks:**
1. Tag sidebar in Flutter showing all used tags + counts
2. Query endpoint: GET /daily/tags → list unique tags
3. Query endpoint: GET /daily/entries?tag=recipe → filter by tag
4. Hashtag extraction Caller
5. Optional: Tag metadata (color, description, icon)

### Phase 3: First-Class Tag Entities (Weeks 5+)

**Goal:** Tag nodes, relationships, graph visualization.

**Tasks:**
1. Add Tag node table to schema
2. Create Tag nodes on first tag usage
3. Create [:TAGGED_WITH] relationships
4. Tag detail screen showing related entries
5. Tag graph visualization

### Phase 4: Tag-to-Entity Materialization (Future)

**Goal:** Seamless tag → Brain entity type discovery.

**Tasks:**
1. `tag_to_entity` Caller template
2. UI to convert tag (e.g., "recipe") to Brain entity type
3. Bulk linking of tagged entries to entity

---

## 8. Implementation Notes

### 8.1 Server Changes (Minimal for MVP)

**File: `modules/daily/module.py`**

**In `on_load()` schema setup:**
```python
# Add to Note table schema (idempotent)
await graph.ensure_node_table(
    "Note",
    {
        # ... existing columns ...
        "tags_json": "STRING",  # new: JSON array ["tag1", "tag2"]
    },
    primary_key="entry_id",
)

# Migrate existing entries (idempotent)
# If tags exist in metadata_json but not in tags_json, extract and copy
```

**In `_write_to_graph()`:**
```python
# When creating/updating entry, populate tags_json if metadata has tags
extra_meta = extra_meta or {}
tags = extra_meta.get("tags", [])
tags_json = json.dumps(tags) if tags else json.dumps([])

await graph.execute_cypher(
    "MERGE (e:Note {entry_id: $entry_id}) "
    "... SET e.tags_json = $tags_json",
    {..., "tags_json": tags_json}
)
```

**In `update_entry()` metadata merge:**
```python
# If metadata includes tags, also update tags_json
if metadata and "tags" in metadata:
    tags = metadata["tags"]
    # Update tags_json alongside metadata_json
```

### 8.2 Client Changes (Flutter)

**In entry editor widget:**
1. Parse entry.metadata.tags (array of strings)
2. Show tag pills with add/remove buttons
3. On tag change, PATCH entry with `{"metadata": {"tags": [...]}}`

**In entry list:**
1. Optional: show tags below entry snippet
2. Tap tag to filter (client-side for MVP)

### 8.3 Caller Tool Integration (Already Done)

**`update_entry_tags` tool (triggered_caller_tools.py):**
- Already exists, already stores in metadata_json
- Works as-is for auto-tagger

**Suggestion:** Auto-update tags_json in same tool call (future refactor).

---

## 9. Open Design Questions

### Q1: Tagging Source of Truth

**Decision needed:** Should tags live in metadata_json only, or also in tags_json column?

**Option A:** metadata_json only (simpler, current state)
- Pro: Single source of truth, less redundancy
- Con: Can't index/query tags efficiently at DB level

**Option B:** Both metadata_json and tags_json (recommended)
- Pro: Metadata stays flexible, tags_json enables queries
- Con: Slight redundancy, need update logic in two places

**Recommendation:** Option B. Tags are important enough to warrant a dedicated column for future indexing.

### Q2: Tag Validation

**Should server enforce tag format?**

Options:
1. Open (any string) — simplest, matches Brain's open ontology
2. Lowercase + hyphenated only (regex: `^[a-z0-9\-]+$`)
3. Whitelist from config

**Recommendation:** Option 1 for MVP. Client can suggest conventions. Validation in Phase 2 if needed.

### Q3: Auto-Tagger Behavior

**Should auto-tagger run on every entry by default?**

Options:
1. Enabled by default (aggressive)
2. Disabled by default (conservative)
3. User opt-in at creation time

**Recommendation:** Option 1 (enabled). User can disable in settings. AI-generated tags are low-risk.

### Q4: Tag Hierarchies

**Support "parent tags" like Brain entity_type hierarchies?**

Options:
1. Flat tags only ("recipe", "dessert", "quick")
2. Path-based tags ("cooking/recipe", "cooking/dessert")
3. Separate tag-to-parent relationships (with Tag nodes, Phase 3)

**Recommendation:** Option 1 for MVP. Flat tags are simpler. Phase 3 can add hierarchies if desired.

### Q5: Interaction with Brain entity_type System

**If user tags entry "recipe", should a Recipe entity_type auto-materialize?**

Options:
1. Never (manual entity creation)
2. On-demand (UI button to materialize)
3. Automatic (tag → entity_type inference)

**Recommendation:** Option 2. User explicitly converts tag to entity type if they want structured Brain support.

---

## 10. Open Questions for the Team

1. **Tag UI priority:** Should tag editing be in entry detail or a separate modal?
2. **Tag search:** How prominent should tag-based filtering be in the entry list?
3. **Auto-tagger verbosity:** Should auto-tagger suggest tags for every entry type, or only certain types (e.g., text only)?
4. **Multi-entry tagging:** Should users be able to bulk-tag multiple entries at once?
5. **Tag export:** Should tags be included when exporting journal entries?

---

## 11. Quick Summary: MVP Scope

| Feature | Scope | Effort |
|---------|-------|--------|
| Tag storage in metadata_json | MVP | ✓ Done |
| Update_entry_tags tool | MVP | ✓ Done |
| CallerDispatcher tag filtering | MVP | ✓ Done |
| Flutter UI: tag picker in entry editor | MVP | 1 day |
| Auto-tagger Caller deployment | MVP | 0.5 days |
| Tags_json column (optional but recommended) | MVP | 0.5 days |
| Tag sidebar with tag list | Phase 2 | 1 day |
| Server tag filter endpoints | Phase 2 | 0.5 days |
| Hashtag extraction | Phase 2 | 1 day |
| First-class Tag entities | Phase 3 | 3-4 days |
| Tag graph visualization | Phase 3+ | TBD |

---

## Conclusion

**Tags are a powerful, lightweight mechanism for:**
1. **Organizing entries** (user-facing UI)
2. **Scoping Callers** (via trigger_filter)
3. **Enabling discovery** (sidebar, search, future Brain integration)

**MVP strategy:**
- Reuse existing metadata_json storage
- Add tags_json column for future query efficiency
- Deploy auto-tagger Caller
- Client implements tag picker UI
- No graph schema revolution needed

**Future expansion:**
- Tag hierarchies, first-class Tag nodes, graph visualization
- Seamless tag-to-entity-type materialization
- Advanced filtering and aggregations

**Next step:** Get buy-in on metadata/tags_json design, then prioritize Phase 1 tasks.
