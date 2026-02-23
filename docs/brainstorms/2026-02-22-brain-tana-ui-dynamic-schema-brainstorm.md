---
date: 2026-02-22
topic: brain-tana-ui-dynamic-schema
status: Draft
priority: P2
module: brain, app
supersedes: "#98"
issue: "#110"
---

**Issue:** #110

# Brain UI: Tana-Inspired Dynamic Schema + Query Interface

## What We're Building

A redesign of the Brain tab from a static, tab-based entity browser into a dynamic knowledge graph UI inspired by Tana. Core change: **schema management moves in-app** (no more editing YAML files to create new types). The UI gains a persistent type sidebar, a card list + detail pane, and a query builder with both filter and natural language modes.

**Supersedes:** #98 (Brain v2 Flutter UI), which assumed YAML-only schemas and tab navigation. This brainstorm captures the evolved direction.

**Builds on:** #94 (Brain v2 TerminusDB backend) — backend is complete; TerminusDB stores the schema already.

---

## Why This Approach

The current UI treats types as hardcoded tabs derived from static YAML files on disk. To evolve Brain into a true extended-mind system, users need to create and shape their own type ontology from within the app — without editing files. TerminusDB already stores the schema as documents in its schema graph; we're just exposing that through an API and UI.

The guiding principle: *"I don't need something to be a file on a system — I just need it to be queryable from the local machine."* TerminusDB satisfies this. YAML files are a bootstrapping mechanism for defaults, not the user's editing surface.

**Daily stays as markdown.** Brain operates independently in v1. Daily–Brain integration (auto-tagging, inline node creation) is a separate future initiative.

**Offline support is deferred.** Brain requires a TerminusDB connection in v1. File-based backup/caching (for offline use) is a future problem.

---

## Key Decisions

### 1. Schema Storage: TerminusDB as Schema Store

The YAML compiler (`schema_compiler.py`) remains for **default/bundled types** only — it bootstraps Person, Project, etc. at startup. User-created types are managed entirely through new backend API endpoints that read and write TerminusDB's schema graph directly.

**New backend endpoints needed:**
- `GET /api/brain/schema/types` — list all types with their fields
- `POST /api/brain/schema/types` — create a new type
- `PUT /api/brain/schema/types/{name}` — update a type (add/edit/remove fields)
- `DELETE /api/brain/schema/types/{name}` — delete a type

**Schema migration notes:** Adding optional fields to existing types is safe in TerminusDB. Removing fields with existing data will need validation. Type deletion with existing entities requires a soft-delete or confirmation step.

### 2. UI Layout: Sidebar + Card List + Detail Pane

Replaces the current `TabBar` + full-screen list:

```
┌──────────────────────────────────────────────────┐
│ Brain                                    [+Query] │
├────────────────┬─────────────────────────────────┤
│ Types          │ Project nodes          [+ New]   │
│                │ ─────────────────────────────── │
│ • Project  12  │ [Parachute            ]          │
│ • Person    8  │   active · 3 people              │
│ • Task      4  │                                  │
│                │ [Learn Vibe Build     ]          │
│                │   active · 1 person              │
│ + New Type     │                                  │
│                │ [Woven Web            ] ─────────┤
│                │   background          │ Detail   │
│                │                       │ ──────── │
│                │                       │ Name:    │
│                │                       │ Woven    │
│                │                       │ Web      │
│                │                       │          │
│                │                       │ Status:  │
│                │                       │ bg       │
│                │                       │          │
│                │                       │ People:  │
│                │                       │ @kieran  │
└────────────────┴───────────────────────┴──────────┘
```

**Mobile:** Sidebar collapses to a bottom sheet or drawer; card list and detail pane stack as standard nav push.

### 3. Schema Editing: Type Manager + Inline Field Addition

**Two entry points, one schema:**

- **Type manager** (click type name → overlay/sheet): Explicit schema view. Shows all fields with type, required/optional, enum values. Add field, rename field, change type (with safety warning if data exists), delete field.
- **Inline on node detail**: "+ Add field to this type" at the bottom of the detail pane. Quick path for schema growth as you're using nodes.

Both write to the same TerminusDB schema endpoint.

### 4. Query Builder: NL → Visual Filters

A filter bar sits above the card list. Default state: no filters (show all nodes of selected type).

**Visual filter builder:**
```
WHERE  status = active  ×
AND    people INCLUDES @kevin  ×
[+ Add filter]
```

**NL input:** A text box at the top. User types "active projects with Kevin" → AI generates the filter conditions → populates the visual builder → user can tweak.

Saved queries: name + filter definition stored as a `SavedQuery` entity type in TerminusDB (or a simple JSON sidecar in `vault/.brain/queries.json` — open question).

### 5. Daily–Brain Link: Deferred

Daily stays as markdown files. Brain operates as a standalone module in v1. The future integration (auto-tagging from Daily, inline node creation via MCP in Chat) is a separate phase.

---

## Open Questions

1. **Saved query storage**: TerminusDB (as a `SavedQuery` entity type) vs flat `vault/.brain/queries.json`? TerminusDB is cleaner long-term but adds a new bootstrapped type. JSON file is simpler for v1.

2. **Schema deletion safety**: When deleting a type that has existing entities, what's the UX? Hard block ("delete all N entities first"), soft archive, or force-with-warning?

3. **NL query model**: Which model powers NL → filter translation? Likely routes through the computer server (same pattern as Chat). The brain module already has MCP tools — perhaps this is just a new `translate_query` tool.

4. **Mobile layout**: On phone, the three-pane layout collapses. Does the sidebar become a bottom type-picker sheet, or a full-screen type list screen?

5. **Field types for v1**: Which field types does the type manager support creating? Recommend: `string`, `enum`, `boolean`, `datetime`, `link to type`. Defer: `array`, `computed`, `formula`.

---

## Out of Scope (v1)

- Daily–Brain integration (auto-tagging, inline node creation from Chat/Daily)
- Offline mode / file-based backup
- Graph visualization (node graph view)
- Type inheritance / hierarchy (`@inherits`)
- Bulk operations (multi-select, bulk tag)
- WOQL query editor (power user)
- Cross-type search

---

## Next Steps

→ `/para-plan #NN` to create an implementation plan covering:
1. Backend: New schema CRUD endpoints
2. Flutter: Home layout redesign (sidebar + cards + detail pane)
3. Flutter: Type manager panel
4. Flutter: Query builder widget
5. Flutter: Saved queries
