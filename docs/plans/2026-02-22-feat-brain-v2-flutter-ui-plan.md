---
title: Brain v2 Flutter UI - Entity browser and management
type: feat
date: 2026-02-22
issue: 98
---

# Brain v2 Flutter UI - Entity Browser and Management

## Overview

Build a Flutter UI for Brain v2's schema-based knowledge graph, enabling users to browse, query, create, and manage typed entities (Person, Project, Note, etc.) with multi-dimensional filtering. Implements schema-first navigation with dynamic property rendering.

**Core Vision:** A queryable personal knowledge graph where users and agents navigate relationships - e.g., "show me people in Boulder interested in technology", "active projects with next actions".

**Context:**
- ✅ Backend complete (TerminusDB, schemas, CRUD API `/api/brain_v2/*`, MCP tools)
- ✅ Brain v1 UI exists (`app/lib/features/brain/`) with proven patterns to reuse
- ⏳ Need schema-aware navigation replacing file-based UI

---

## Problem Statement

Brain v1 UI is file-based with simple substring search. It doesn't understand entity types, relationships, or schema-defined properties. Users can't filter by "people in Boulder" or navigate entity graphs.

Brain v2's backend provides a typed knowledge graph (Person, Project, Note) with relationships and version control, but no UI to access it from the app. Users must use HTTP API or wait for MCP tools to be integrated.

**Why This Matters:**
- **Typed navigation:** Users think in entity types ("show me projects", not "search for files tagged project")
- **Property filtering:** Need to query by location, tags, status - not just full-text search
- **Relationship context:** Navigate connections between entities (project → people → meetings)
- **Agent parity:** UI should expose same capabilities as MCP tools (CRUD, traverse graph)

---

## Proposed Solution

### Schema-First Tab Navigation

**Top-level entity type tabs** (Person, Project, Note, etc.) with type-specific lists, dynamic property filtering, and schema-driven forms.

**Flow:**
```
[Entity Type Tabs] Person | Project | Note
     ↓
[Search + Property Filters] Location: Boulder, Interest: Technology
     ↓
[Entity Cards] Name, primary fields, tags
     ↓
[Detail View] All fields + relationship links
     ↓
[Create/Edit Forms] Dynamic fields from schema
```

**Key Capabilities:**
1. **Browse by type** - Tab per entity type with instant type discovery
2. **Smart filters** - Search + schema-defined property chips
3. **Dynamic forms** - Create/edit with field types from YAML schemas
4. **Relationship links** - Navigate connections (phase 1: clickable chips)

---

## Technical Approach

### Architecture

```
Screen Layer (Tabs, Lists, Details, Forms)
      ↓
Riverpod Providers (Schema list, entity lists, entity details, selected type)
      ↓
BrainV2Service (HTTP client for /api/brain_v2/*)
      ↓
Server API (TerminusDB backend)
```

**Reuse Brain v1 Patterns:**
- Service singleton with HTTP client
- FutureProvider.autoDispose for lists
- FutureProvider.family for parameterized queries (detail by ID)
- StateProvider for UI state (selected tab, search query)
- AsyncValue.when() for loading/error/data

**New for Brain v2:**
- Schema-driven UI (fetch schemas, render dynamic fields)
- Type-based navigation (tab controller with entity types)
- Dynamic form builder (field type → widget mapping)
- Relationship rendering (entity IRI → clickable chip)

### File Structure

```
app/lib/features/brain_v2/
├── models/
│   ├── brain_v2_entity.dart         # Entity model (@id, @type, fields)
│   ├── brain_v2_schema.dart         # Schema definition
│   └── brain_v2_field.dart          # Field metadata (type, required, enum values)
├── services/
│   └── brain_v2_service.dart        # HTTP client for /api/brain_v2/*
├── providers/
│   ├── brain_v2_schema_provider.dart      # FutureProvider for schema list
│   ├── brain_v2_entity_list_provider.dart # FutureProvider.family(type)
│   ├── brain_v2_entity_detail_provider.dart # FutureProvider.family(id)
│   └── brain_v2_ui_state_provider.dart    # StateProvider for selected type, search
├── screens/
│   ├── brain_v2_home_screen.dart    # Tab navigation wrapper
│   ├── brain_v2_entity_list_screen.dart # List with search/filters for one type
│   ├── brain_v2_entity_detail_screen.dart # Full entity view
│   └── brain_v2_entity_form_screen.dart   # Create/edit dynamic form
└── widgets/
    ├── brain_v2_entity_card.dart    # List item (name, fields, tags)
    ├── brain_v2_property_filter.dart # Collapsible filter chips
    ├── brain_v2_field_widget.dart   # Dynamic field renderer (string/enum/date/etc)
    ├── brain_v2_relationship_chip.dart # Clickable entity link
    └── brain_v2_form_builder.dart   # Schema → form field generator
```

### Implementation Phases

#### Phase 1: Foundation (Models + Service)

**Tasks:**
- [ ] Create `BrainV2Entity` model with `@id`, `@type`, dynamic `fields` map
- [ ] Create `BrainV2Schema` model (id, name, field definitions)
- [ ] Create `BrainV2Field` model (name, type, required, enumValues)
- [ ] Implement `BrainV2Service`:
  - `Future<List<BrainV2Schema>> listSchemas()`
  - `Future<List<BrainV2Entity>> queryEntities(String type, {int limit, int offset})`
  - `Future<BrainV2Entity?> getEntity(String id)`
  - `Future<String> createEntity(String type, Map<String, dynamic> data, {String? commitMsg})`
  - `Future<void> updateEntity(String id, Map<String, dynamic> data, {String? commitMsg})`
  - `Future<void> deleteEntity(String id, {String? commitMsg})`
- [ ] Add error handling (catch HTTP exceptions, return user-friendly messages)
- [ ] Write service tests with mock server responses

**Files:**
- `app/lib/features/brain_v2/models/brain_v2_entity.dart`
- `app/lib/features/brain_v2/models/brain_v2_schema.dart`
- `app/lib/features/brain_v2/models/brain_v2_field.dart`
- `app/lib/features/brain_v2/services/brain_v2_service.dart`

**Success Criteria:**
- Service successfully fetches schemas from `/api/brain_v2/schemas`
- Service queries entities by type from `/api/brain_v2/entities/{type}`
- Models parse TerminusDB JSON (`@id`, `@type`, schema fields)
- Error handling returns clear messages (not raw HTTP errors)

**Estimated Effort:** 3-4 hours

---

#### Phase 2: Riverpod State Layer

**Tasks:**
- [ ] Create `brainV2ServiceProvider` (singleton service instance)
- [ ] Create `brainV2SchemaListProvider` (FutureProvider - loads schemas on init)
- [ ] Create `brainV2EntityListProvider(String type)` (FutureProvider.family - queries entities by type)
- [ ] Create `brainV2EntityDetailProvider(String id)` (FutureProvider.family - fetches single entity)
- [ ] Create `brainV2SelectedTypeProvider` (StateProvider<String?> - currently selected tab)
- [ ] Create `brainV2SearchQueryProvider` (StateProvider<String> - search text)
- [ ] Add auto-invalidation: when entity created/updated/deleted, invalidate list providers

**Files:**
- `app/lib/features/brain_v2/providers/brain_v2_service_provider.dart`
- `app/lib/features/brain_v2/providers/brain_v2_schema_provider.dart`
- `app/lib/features/brain_v2/providers/brain_v2_entity_list_provider.dart`
- `app/lib/features/brain_v2/providers/brain_v2_entity_detail_provider.dart`
- `app/lib/features/brain_v2/providers/brain_v2_ui_state_provider.dart`

**Success Criteria:**
- Providers load data from service on first read
- Family providers accept parameters (type, id)
- State providers update UI reactively
- Invalidation triggers refetch after mutations

**Estimated Effort:** 2-3 hours

---

#### Phase 3: Tab Navigation + Entity List

**Tasks:**
- [ ] Create `BrainV2HomeScreen` with TabController (entity types as tabs)
- [ ] Load schemas via `brainV2SchemaListProvider`, create tab per schema
- [ ] Use `SingleTickerProviderStateMixin` + `TabController` (dispose in dispose())
- [ ] Create `BrainV2EntityListScreen` (one instance per tab):
  - Search TextField with debounced query update (300ms timer)
  - ListView.separated with entity cards
  - AsyncValue.when() for loading/error/empty states
  - Pull-to-refresh (RefreshIndicator)
- [ ] Create `BrainV2EntityCard` widget:
  - Display entity name (from `name` or `title` field, fallback to `@id`)
  - Show 2-3 primary fields (infer from schema or use first fields)
  - Wrap tags with `BrainV2TagChip` (reuse Brain v1 style)
  - Tap → navigate to detail screen
- [ ] Add FloatingActionButton on each tab (tap → create form for current type)
- [ ] Style with BrandColors (forest, nightForest, cream, charcoal)

**Files:**
- `app/lib/features/brain_v2/screens/brain_v2_home_screen.dart`
- `app/lib/features/brain_v2/screens/brain_v2_entity_list_screen.dart`
- `app/lib/features/brain_v2/widgets/brain_v2_entity_card.dart`

**Success Criteria:**
- Tabs render for each available schema (Person, Project, Note)
- Switching tabs loads correct entity type
- Search filters entities client-side (substring match on name/fields)
- Cards show entity name, primary fields, tags
- Tap card navigates to detail screen
- FAB opens create form for current tab type

**Estimated Effort:** 4-5 hours

---

#### Phase 4: Entity Detail Screen

**Tasks:**
- [ ] Create `BrainV2EntityDetailScreen(String entityId)`:
  - Fetch entity via `brainV2EntityDetailProvider(entityId)`
  - AppBar with entity name + edit/delete actions
  - Display all entity fields dynamically (use schema to get field types)
  - Show tags as Wrap of chips
  - Render relationships as labeled sections with clickable chips
- [ ] Create `BrainV2FieldWidget` (dynamic field renderer):
  - `string` → Text widget
  - `datetime` → formatted date/time
  - `boolean` → Icon (check/x)
  - `enum` → Text with color badge
  - `array<string>` → Wrap of chips
  - `array<Entity>` → Relationship chips (see below)
- [ ] Create `BrainV2RelationshipChip`:
  - Parse entity IRI (e.g., "Person/john_doe" → "john_doe")
  - Fetch entity name via detail provider
  - Render as chip with forest background
  - Tap → navigate to related entity detail
- [ ] Add edit button → navigate to form screen (pre-fill with current data)
- [ ] Add delete button → confirm dialog → call service → pop to list

**Files:**
- `app/lib/features/brain_v2/screens/brain_v2_entity_detail_screen.dart`
- `app/lib/features/brain_v2/widgets/brain_v2_field_widget.dart`
- `app/lib/features/brain_v2/widgets/brain_v2_relationship_chip.dart`

**Success Criteria:**
- Detail screen shows all entity fields with correct types
- Relationships render as clickable chips
- Tap relationship chip navigates to related entity
- Edit button opens pre-filled form
- Delete button removes entity and returns to list

**Estimated Effort:** 4-5 hours

---

#### Phase 5: Create/Edit Form

**Tasks:**
- [ ] Create `BrainV2EntityFormScreen({String? entityId, required String entityType})`:
  - If `entityId` provided → edit mode (fetch existing data)
  - Else → create mode (empty fields)
  - Load schema for `entityType` to get field definitions
  - Generate form fields dynamically from schema
- [ ] Create `BrainV2FormBuilder`:
  - Parse schema fields, create TextEditingController per field
  - Field type mapping:
    - `string` → TextField
    - `integer` → TextField(keyboardType: number, inputFormatter: digits only)
    - `boolean` → SwitchListTile
    - `enum` → DropdownButton(items from schema.enumValues)
    - `datetime` → TextField + IconButton → DatePicker
    - `array<string>` → ChipInput (comma-separated, press enter to add chip)
    - `array<Entity>` → Entity selector (search + select)
  - Mark required fields with asterisk
  - Add validation (required fields, enum constraints)
- [ ] Add commit message field (optional, defaults to "Create {Type}" or "Update {Type}")
- [ ] Submit button:
  - Validate all fields
  - Call service.createEntity() or service.updateEntity()
  - Show SnackBar on success/error
  - Invalidate entity list provider
  - Pop to previous screen

**Files:**
- `app/lib/features/brain_v2/screens/brain_v2_entity_form_screen.dart`
- `app/lib/features/brain_v2/widgets/brain_v2_form_builder.dart`

**Success Criteria:**
- Form renders all schema fields with correct input types
- Required fields validated on submit
- Create mode adds new entity to database
- Edit mode updates existing entity
- Success shows SnackBar and refreshes list
- Errors display user-friendly messages

**Estimated Effort:** 5-6 hours

---

#### Phase 6: Property Filters (Optional - Phase 1.5)

**Tasks:**
- [ ] Create `BrainV2PropertyFilter` widget:
  - Collapsible section above entity list
  - Render filter chips for schema-defined filterable fields
  - Each chip has multi-select (Location: [Boulder, Denver])
  - Apply filters client-side (filter entity list by selected values)
- [ ] Add filter state to `brainV2UiStateProvider` (Map<String, List<String>>)
- [ ] Update entity list to apply filters after search

**Files:**
- `app/lib/features/brain_v2/widgets/brain_v2_property_filter.dart`

**Success Criteria:**
- Filter section shows schema-defined filterable fields
- Selecting filter values filters entity list
- Filters combine with search (AND logic)
- Clearing filters resets list

**Estimated Effort:** 3-4 hours (defer if time-constrained)

---

## Acceptance Criteria

### Functional Requirements

**Phase 1 MVP:**
- [ ] User can switch between entity type tabs (Person, Project, Note)
- [ ] Each tab shows list of entities for that type
- [ ] User can search entities by name within a type
- [ ] Tapping entity card opens detail view with all fields
- [ ] User can create new entity via FAB (dynamic form based on schema)
- [ ] User can edit existing entity (pre-filled form)
- [ ] User can delete entity (with confirmation)
- [ ] Relationships display as clickable chips
- [ ] Tapping relationship chip navigates to related entity

**UI/UX:**
- [ ] Dark mode support (BrandColors.nightForest, etc.)
- [ ] Loading states (CircularProgressIndicator)
- [ ] Error states (friendly messages, retry button)
- [ ] Empty states ("No entities yet", "Create your first...")
- [ ] Pull-to-refresh on lists
- [ ] Smooth tab transitions

**Integration:**
- [ ] All API calls use `/api/brain_v2/*` endpoints
- [ ] Entity mutations invalidate Riverpod providers
- [ ] Schema changes (new YAML files) reflected after app restart

### Non-Functional Requirements

**Performance:**
- [ ] Tab switching < 100ms (cached data)
- [ ] Entity list loads < 1s for 100 entities
- [ ] Form validation instant (<50ms)

**Code Quality:**
- [ ] Follow Brain v1 patterns (service + providers + screens/widgets)
- [ ] Use BrandColors tokens (no hardcoded colors)
- [ ] Proper TextEditingController disposal
- [ ] AsyncValue.when() for all async data
- [ ] Null safety (no bang operators without justification)

**Testing:**
- [ ] Service unit tests (mock HTTP client)
- [ ] Provider tests (mock service)
- [ ] Widget tests for key screens (home, list, detail, form)

---

## Success Metrics

**Adoption:**
- Users create 10+ entities in first week
- 80% of users browse Brain v2 UI (vs. 20% using MCP tools/API)

**Engagement:**
- Users return to Brain v2 screen 3+ times per session
- Average 5+ entity views per session

**Quality:**
- <5% error rate on entity creation
- <1% crash rate in Brain v2 screens
- 0 critical bugs in first release

---

## Dependencies & Prerequisites

**Before Starting:**
- Backend: ✅ Brain v2 API complete (`/api/brain_v2/*`)
- Schemas: ✅ Example schemas exist (`~/Parachute/.brain/schemas/*.yaml`)
- Server: ✅ TerminusDB running (docker-compose.brain.yml)

**During Implementation:**
- Flutter packages: ✅ Already have `http`, `riverpod`, `flutter_markdown`
- Design system: ✅ BrandColors, Spacing, Radii defined in `design_tokens.dart`
- Navigation: ✅ Tab pattern from existing screens (CapabilitiesScreen)

**Potential Blockers:**
- Schema format changes (YAML → JSON schema structure mismatch)
- TerminusDB IRI format not matching assumptions
- Performance issues with 100+ entities (pagination needed)

---

## Risk Analysis & Mitigation

### Risk 1: Dynamic Form Complexity
**Risk:** Generating forms from arbitrary schemas is complex, edge cases abound
**Likelihood:** High | **Impact:** Medium
**Mitigation:**
- Start with simple field types (string, boolean, enum)
- Defer complex types (nested objects, union types) to Phase 2
- Add "Manual JSON Edit" fallback for unsupported field types

### Risk 2: Relationship Rendering Performance
**Risk:** Entity cards fetching relationship names on every render (N+1 queries)
**Likelihood:** Medium | **Impact:** High
**Mitigation:**
- Cache entity names in provider (Map<String, String>)
- Batch-fetch related entities (single API call for all relationships in list)
- Lazy-load relationships (only fetch when detail screen opened)

### Risk 3: Schema-UI Mismatch
**Risk:** YAML schemas use features TerminusDB doesn't support (or vice versa)
**Likelihood:** Low | **Impact:** Medium
**Mitigation:**
- Validate schemas against TerminusDB capabilities during compilation
- Document supported field types clearly in README
- Add schema validation errors to UI (show which fields failed)

### Risk 4: Offline Behavior Undefined
**Risk:** App crashes when server unreachable, unclear UX
**Likelihood:** Medium | **Impact:** High
**Mitigation:**
- Check server health on app startup
- Show "Server Unavailable" banner when offline
- Disable create/edit actions gracefully
- Cache last-fetched entity list for read-only browsing

---

## Future Considerations

**Phase 2 Enhancements:**
- Property filtering UI (multi-select chips, date ranges)
- Graph visualization (force-directed graph of relationships)
- Bulk operations (multi-select, bulk delete/tag)
- Advanced search (WOQL query builder)
- Offline mode (queue mutations, sync on reconnect)

**Phase 3 Innovations:**
- AI-assisted entity creation (suggest fields from text input)
- Saved views/filters ("Active Projects", "People in Boulder")
- Entity templates (quick-create with pre-filled fields)
- Cross-entity search (search all types at once)
- Real-time sync (WebSocket updates when entities change)

**Integration Opportunities:**
- Daily module: Auto-create entities from journal entries
- Chat module: Reference entities in messages ("@person:john")
- Vault module: Link files to entities (project docs, person photos)

---

## Documentation Plan

**Code Documentation:**
- [ ] Add doc comments to all public APIs (services, providers, widgets)
- [ ] Document field type → widget mapping in BrainV2FormBuilder
- [ ] Add schema examples to model files

**User Documentation:**
- [ ] README section: "Using Brain v2 UI"
- [ ] Schema authoring guide (YAML format, field types, relationships)
- [ ] Troubleshooting: "Entity not appearing?", "Form validation failing?"

**Developer Documentation:**
- [ ] Architecture diagram (screen → provider → service → API)
- [ ] Adding new field types (extend BrainV2FieldWidget)
- [ ] Provider invalidation strategy (when to refresh)

---

## References & Research

### Internal References

**Existing Brain v1 UI:**
- `app/lib/features/brain/screens/brain_screen.dart` - Search + list pattern
- `app/lib/features/brain/widgets/brain_entity_card.dart` - Card layout
- `app/lib/features/brain/services/brain_service.dart` - HTTP client pattern
- `app/lib/features/brain/providers/brain_providers.dart` - Riverpod structure

**Design System:**
- `app/lib/core/theme/design_tokens.dart` - BrandColors, Spacing, Radii, Typography

**Tab Navigation:**
- `app/lib/features/chat/screens/capabilities_screen.dart` - TabController pattern

**Dynamic Forms:**
- `app/lib/features/chat/widgets/session_config_sheet.dart` - Form with validation

**Backend API:**
- `computer/modules/brain_v2/README.md` - API documentation
- `computer/modules/brain_v2/module.py` - FastAPI route definitions
- `computer/modules/brain_v2/models.py` - Pydantic request/response models

**Example Schemas:**
- `~/Parachute/.brain/schemas/person.yaml`
- `~/Parachute/.brain/schemas/project.yaml`
- `~/Parachute/.brain/schemas/note.yaml`

### External References

**Flutter Best Practices:**
- [Riverpod Documentation](https://riverpod.dev/docs/introduction/getting_started) - Provider patterns
- [Material Design 3](https://m3.material.io/) - Tab navigation, forms
- [Flutter Performance](https://docs.flutter.dev/perf/best-practices) - ListView optimization

**Similar Tools:**
- [Tana](https://tana.inc/) - Supertag structure, type-based navigation
- [Notion](https://www.notion.so/) - Database views, property filters
- [Obsidian](https://obsidian.md/) - Graph view, backlinks

### Related Work

**Backend Issues:**
- #94 - Brain v2 TerminusDB MVP (backend complete)
- #98 - Brain v2 Flutter UI (this plan)

**Related Features:**
- Brain v1 UI (file-based, to be replaced)
- MCP tools (agent-native CRUD, already functional)

---

## Implementation Checklist

### Phase 1: Foundation
- [ ] `brain_v2_entity.dart` model with @id, @type, fields
- [ ] `brain_v2_schema.dart` model with field definitions
- [ ] `brain_v2_field.dart` model with type, required, enumValues
- [ ] `brain_v2_service.dart` with all CRUD methods
- [ ] Service tests (mock HTTP responses)

### Phase 2: State Layer
- [ ] `brain_v2_service_provider.dart` (singleton)
- [ ] `brain_v2_schema_provider.dart` (FutureProvider)
- [ ] `brain_v2_entity_list_provider.dart` (FutureProvider.family)
- [ ] `brain_v2_entity_detail_provider.dart` (FutureProvider.family)
- [ ] `brain_v2_ui_state_provider.dart` (StateProvider for selected type, search)
- [ ] Provider invalidation on mutations

### Phase 3: Tab Navigation
- [ ] `brain_v2_home_screen.dart` with TabController
- [ ] `brain_v2_entity_list_screen.dart` with search + ListView
- [ ] `brain_v2_entity_card.dart` widget
- [ ] FloatingActionButton for create
- [ ] Dark mode support

### Phase 4: Detail Screen
- [ ] `brain_v2_entity_detail_screen.dart` with all fields
- [ ] `brain_v2_field_widget.dart` (dynamic renderer)
- [ ] `brain_v2_relationship_chip.dart` (clickable links)
- [ ] Edit/delete actions

### Phase 5: Forms
- [ ] `brain_v2_entity_form_screen.dart` (create/edit)
- [ ] `brain_v2_form_builder.dart` (dynamic field generation)
- [ ] Field type mapping (string, enum, date, etc.)
- [ ] Validation + submit

### Phase 6: Polish
- [ ] Error handling (friendly messages)
- [ ] Empty states
- [ ] Loading states
- [ ] Pull-to-refresh
- [ ] Property filters (optional)

### Testing & Documentation
- [ ] Unit tests for service
- [ ] Provider tests
- [ ] Widget tests
- [ ] Update README with usage guide
- [ ] Add schema authoring docs

---

## Open Questions

1. **Property Filter UI:** Collapsible section vs. inline chips vs. bottom sheet?
   - **Decision:** Defer to Phase 2 - start with search-only, add filters when users request

2. **Schema Management:** Read-only in app vs. full schema editor?
   - **Decision:** Read-only for MVP - YAML editing is safer, advanced users can edit files

3. **Offline Behavior:** Cached read-only vs. queue mutations vs. full offline mode?
   - **Decision:** Server unavailable banner + cached read-only - aligns with current app patterns

4. **Relationship UI:** Chips vs. list vs. graph visualization?
   - **Decision:** Chips for Phase 1 (simple, proven), graph viz for Phase 2

5. **Multi-Entity Selection:** Bulk actions in Phase 1 or defer?
   - **Decision:** Defer to Phase 2 (YAGNI - wait for user demand)
