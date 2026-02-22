# Brain v2 Flutter UI - Entity Browser and Management

**Date:** 2026-02-22
**Status:** Brainstorm
**Priority:** P2
**Issue:** #98

---

## What We're Building

A Flutter UI for Brain v2's schema-based knowledge graph, enabling users to browse, query, create, and manage typed entities (Person, Project, Note, etc.) with multi-dimensional filtering. Think Tana's supertag structure but in Parachute.

**Core Vision:** A dynamic, queryable personal knowledge graph where both users and agents can navigate relationships. Examples: "show me people in Boulder interested in technology", "active projects with next actions", "grocery list items by store".

**Backend Status:** ✅ Complete (TerminusDB, schemas, CRUD API, MCP tools all functional)

**UI Status:** Brain v1 UI exists but is file-based. Brain v2 needs schema-aware navigation with dynamic property rendering.

---

## Why This Approach (Schema-First Navigation)

### User Mental Model
Users think in entity types: "I want to see my projects", "I want to find people in Boulder". Schema-first navigation matches this natural categorization.

### Foundation for Advanced Filtering
Starting with type-based organization creates a clear path to multi-property filters:
- Today: "Show me all Projects"
- Next iteration: "Show me Projects where status=active and owner=me"
- Future: "Show me People in Boulder interested in technology"

### Schema-Aware from Day One
Unlike Brain v1's generic search, Brain v2's UI knows about entity types, fields, and relationships from the start. This enables:
- Type-specific property filters
- Dynamic form generation based on schemas
- Relationship navigation within context

### Reuses Proven Patterns
Brain v1's search → results → detail flow works well. We're adapting it, not replacing it:
- Keep: List/detail navigation, AsyncValue error handling, BrandColors theming
- Change: Add type selector, dynamic property rendering, schema-driven forms

---

## Key Decisions

### 1. Navigation Structure: Entity Type Tabs

**Decision:** Top-level tab selector for entity types (Person, Project, Note, etc.)

**Why:**
- Immediate type discovery (no hidden schemas)
- Contextual actions (create button spawns correct type)
- Foundation for type-specific filters
- Familiar pattern (similar to module tabs)

**Alternative Considered:** Unified search-first (like Brain v1)
- **Rejected:** Harder to discover entity types, less intuitive for multi-property filtering

### 2. Entity List: Smart Property Filtering

**Decision:** Each entity type tab shows a filterable list with type-specific properties

**Implementation:**
- Top: Search bar (filters by name/content)
- Below search: Property filter chips (schema-defined)
- List: Entity cards with primary fields + tags
- Tap card → detail view

**Example (Person type):**
```
[Search: "Sarah"]
[Filters: Location: Boulder | Interest: Technology]
┌─────────────────────────────┐
│ Sarah Chen                  │
│ Boulder, CO · Technology    │
│ Last contact: 2 days ago    │
└─────────────────────────────┘
```

### 3. Entity Detail: Relationship Links (Phase 1)

**Decision:** Show relationships as clickable entity links, defer graph visualization

**Phase 1 (MVP):**
- Display related entities as chips/links
- Tap link → navigate to related entity detail
- Show relationship type label

**Phase 2 (Future):**
- Graph visualization of connections
- Multi-hop traversal UI
- Relationship creation/deletion

**Example:**
```
John Doe
─────────
Location: Boulder, CO
Interests: Technology, Music

Related Projects:
[Parachute] [Learn Vibe Build]

Related People:
[Sarah Chen] [Kevin (Regen Hub)]
```

### 4. Entity Creation: Dynamic Schema Forms

**Decision:** Generate forms dynamically from schema definitions

**Field Type Mapping:**
- `string` → TextField
- `enum` → DropdownButton with schema values
- `boolean` → Switch
- `datetime` → DatePicker
- `array<string>` → Chip input (for tags)
- `array<Entity>` → Entity selector (for relationships)

**Validation:** Schema-defined (required fields, enums, constraints)

**Commit Message:** Optional text field (defaults to "Create {EntityType}")

### 5. Server Integration: Reuse Brain v1 Service Pattern

**Decision:** Single BrainV2Service with HTTP client, Riverpod providers for state

**Services:**
- `BrainV2Service` - HTTP client for `/api/brain_v2/*` endpoints
- Methods: `listSchemas()`, `queryEntities()`, `getEntity()`, `createEntity()`, `updateEntity()`, `deleteEntity()`

**Providers:**
- `brainV2SchemaListProvider` - FutureProvider for available schemas
- `brainV2EntityListProvider(type)` - FutureProvider.family for entity lists
- `brainV2EntityDetailProvider(id)` - FutureProvider.family for single entity
- `brainV2SelectedTypeProvider` - StateProvider for current tab

**Error Handling:** AsyncValue.when() pattern from Brain v1

---

## Open Questions

### 1. Property Filter UI Design
**Question:** How should property filters be surfaced?
- **Option A:** Collapsible "Filters" section with schema-defined fields
- **Option B:** Inline filter chips above list (space-constrained on mobile)
- **Option C:** Bottom sheet with filter builder

**Leaning:** Option A (collapsible section) - balances discoverability with screen real estate

### 2. Schema Management in UI
**Question:** Should users create/edit schemas from the app or only via YAML?
- **Option A:** Read-only schema display, edit YAML files externally
- **Option B:** Full schema editor in app

**Leaning:** Option A for MVP - schema editing is advanced/rare, YAML is safer

### 3. Multi-Entity Selection
**Question:** Should users be able to bulk delete/tag entities?
- **Phase 1:** Single-entity actions only
- **Phase 2:** Add selection mode + bulk actions

**Decision:** Defer to Phase 2 (YAGNI - build it when users ask)

### 4. Offline Behavior
**Question:** How should the app behave when server is unreachable?
- **Option A:** Show cached entities, disable create/edit
- **Option B:** Queue mutations, sync when online
- **Option C:** Full offline mode with local TerminusDB

**Leaning:** Option A for MVP (consistent with current app architecture)

---

## Success Criteria

**Must Have (Phase 1):**
- ✅ Browse entities by type (tab navigation)
- ✅ View entity details with all fields
- ✅ Create new entities via schema forms
- ✅ Edit existing entities
- ✅ Delete entities
- ✅ Basic search within entity type
- ✅ Navigate relationships via links

**Nice to Have (Phase 2):**
- Property-based filtering (location, tags, custom fields)
- Graph visualization of relationships
- Bulk operations (multi-select, bulk tag)
- Advanced search (multi-property queries)
- Offline mode with sync

**Future Explorations:**
- AI-assisted entity creation (suggest fields, auto-categorize)
- Saved views/filters (e.g., "Active Projects")
- Entity templates (quick-create common types)
- Cross-entity search (find across all types)

---

## Technical Constraints

**Backend API:** All endpoints exist at `/api/brain_v2/*` (GET/POST/PUT/DELETE)

**Schema Format:** YAML files in `~/Parachute/.brain/schemas/*.yaml`

**Entity Structure:** TerminusDB JSON with `@id`, `@type`, and schema-defined fields

**Relationships:** Array fields containing entity IRIs (e.g., `related_projects: ["Project/parachute"]`)

**Validation:** Server-side via TerminusDB schema enforcement

---

## Dependencies

**Before Implementation:**
- Backend: ✅ Brain v2 complete (TerminusDB, API, MCP tools)
- Schemas: Need 3-5 example schemas for testing (Person, Project, Note, Task, Contact)

**During Implementation:**
- New models: BrainV2Entity, BrainV2Schema, BrainV2Field
- New service: BrainV2Service (HTTP client)
- New providers: Schema list, entity lists, entity details
- New screens: BrainV2TypeSelector, BrainV2EntityList, BrainV2EntityDetail, BrainV2EntityForm
- New widgets: Dynamic form builder, property filter chips, relationship links

---

## Out of Scope (Explicitly Deferred)

- ❌ Graph visualization (Phase 2)
- ❌ Bulk operations (Phase 2)
- ❌ Advanced filtering UI (Phase 2)
- ❌ Schema editor in app (use YAML files)
- ❌ Offline mode with local DB (complex, defer)
- ❌ Cross-entity search (Phase 2 with WOQL full-text)
- ❌ Entity templates (wait for user demand)

---

## References

**Related Work:**
- Brain v1 UI: `app/lib/features/brain/` (patterns to reuse)
- Brain v2 Backend: `computer/modules/brain_v2/` (API reference)
- Schema Examples: `~/Parachute/.brain/schemas/*.yaml`

**Similar Tools:**
- Tana (supertag structure, type-based navigation)
- Notion (database views, property filters)
- Obsidian (graph view, backlinks)

**Key Principles:**
- Schema-first (types are first-class)
- Agent-native (MCP tools enable autonomous operation)
- YAGNI (build the minimum, iterate based on usage)
