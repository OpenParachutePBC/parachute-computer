---
title: Brain UI — Tana-Inspired Dynamic Schema + Query Interface
type: feat
date: 2026-02-22
issue: 110
---

# Brain UI — Tana-Inspired Dynamic Schema + Query Interface

## Enhancement Summary

**Deepened on:** 2026-02-22
**Research agents used:** Flutter reviewer, Python reviewer, Flutter adaptive layout, Architecture strategist, Security sentinel, Agent-native reviewer, Parachute conventions reviewer, Code simplicity reviewer, Performance oracle

### Key Improvements Discovered

1. **CRITICAL — Route namespace change:** `/api/brain/schema/types` → `/api/brain/types` to stay consistent with existing `/api/brain/entities` pattern and avoid conflict with `/api/brain/schemas`.
2. **CRITICAL — `BrainQueryService` must use HTTP, not direct vault file I/O.** Flutter app must not write to `vault/.brain/` — that's Brain module territory. Saved queries need backend endpoints.
3. **CRITICAL — `_compile_field()` signature and enum ordering.** Enum docs must be inserted into TerminusDB BEFORE the Class doc that references them. The existing `_compile_field()` requires `class_name`, `field_name`, `enum_docs` params — the plan as written drops them.
4. **CRITICAL — Schema persistence across restarts.** `connect()` must be additive-only; user-created types must survive server restart. Must be an explicit acceptance criterion.
5. **CRITICAL — `LayoutBuilder` must not contain entity state.** `selectedEntityId` check inside the `LayoutBuilder` callback causes sidebar + list rebuilds on every entity tap. Fix: `_BrainWideLayout` as a separate `ConsumerWidget`.
6. **CRITICAL — Reserved TerminusDB names must be blocked.** Type names `Class`, `Enum`, `Set`, `Optional`, `TaggedUnion` would silently corrupt the schema graph.
7. **HIGH — Threading safety.** `WOQLClient` shared instance across `asyncio.to_thread()` calls is not thread-safe (`requests.Session` is not thread-safe). Add `threading.Lock`.
8. **HIGH — Saved query MCP tools missing.** Plan has 0 MCP tools for query management; 4 are needed for agent parity.
9. **HIGH — `delete_document` wrong argument.** Needs string ID (`"Project"`) not a dict.

### New Considerations

- `BrainLayoutMode` enum needed (not just `bool isWide`) to enable animated transitions
- `AnimatedSize` is correct for detail pane (not conditional `Row` child, not `AnimatedContainer`)
- `NotifierProvider` instead of `StateProvider<List<...>>` for filter list
- `sealed class FilterValue` instead of `dynamic value` in filter model
- N+1 count queries → `asyncio.gather()` for concurrent execution (O(1) latency)
- `select()` on `brainSelectedTypeProvider` in sidebar rows (O(1) rebuild per type switch)
- `ValueKey` on filter chips for correct reconciliation
- `ConfigDict(strict=True)` + validators needed on `FieldSpec`
- `BrainTypeManagerSheet` must be `ConsumerStatefulWidget`, not `StatefulWidget`

---

## Overview

Redesign the Brain tab from a static, tab-based entity browser into a dynamic knowledge graph UI inspired by Tana. Two tracks of work run in parallel: **backend** (new schema CRUD API endpoints) and **Flutter** (new adaptive 3-pane layout, type manager sheet, query builder).

The current tab-based `BrainHomeScreen` + `TabBar` is replaced by an adaptive sidebar + card list + detail pane layout modelled on `chat_shell.dart`. Schema management moves in-app — users create and edit types from within Brain instead of editing YAML files.

**Builds on:** #94 (TerminusDB backend complete), #98 (tab-based Flutter UI — the starting point for the new layout).

---

## Technical Approach

### What Already Exists (reuse / adapt)

| Asset | Location | Status |
|-------|----------|--------|
| `BrainSchema`, `BrainField`, `BrainEntity` models | `app/lib/features/brain/models/` | Keep, extend |
| `BrainService` HTTP client | `app/lib/features/brain/services/brain_service.dart` | Add new schema endpoints |
| Riverpod providers | `app/lib/features/brain/providers/` | Keep, add 4 new |
| `BrainEntityCard`, `BrainFieldWidget`, `BrainFormBuilder`, `BrainRelationshipChip` | `app/lib/features/brain/widgets/` | Keep |
| `BrainEntityDetailScreen`, `BrainEntityFormScreen` | `app/lib/features/brain/screens/` | Keep, adapt detail as inline pane |
| `KnowledgeGraphService` + TerminusDB client | `computer/modules/brain/knowledge_graph.py` | Add 3 new methods |
| `module.py` FastAPI router | `computer/modules/brain/module.py` | Add 4 new routes |
| Adaptive layout pattern | `app/lib/features/chat/chat_shell.dart` | Copy `LayoutBuilder` approach |

### What Gets Replaced

- `BrainHomeScreen` — TabBar → adaptive sidebar layout
- `BrainEntityListScreen` — full-screen → card column in split layout

### New Files

```
computer/modules/brain/
└── (module.py additions — no new files needed)

app/lib/features/brain/
├── widgets/
│   ├── brain_type_sidebar.dart        # Left panel: type list + counts + New Type button
│   ├── brain_type_manager_sheet.dart  # Modal sheet: schema field CRUD
│   └── brain_query_bar.dart           # Filter bar: visual conditions
└── (screens/ and providers/ additions — no new files for most)
```

---

## Implementation Phases

### Phase 1: Backend — Schema CRUD API

**Goal:** Expose TerminusDB's schema graph read/write via four new API endpoints and corresponding MCP tools. Enables the Flutter type manager UI.

#### 1.1 New `KnowledgeGraphService` methods

**File:** `computer/modules/brain/knowledge_graph.py`

Add three async methods after `list_schemas()`. **Critical implementation details:**

```python
async def create_schema_type(
    self,
    name: str,
    fields: dict[str, Any],
    key_strategy: str = "Random",
    description: str | None = None,
) -> None:
    """Insert a new Class document into the TerminusDB schema graph.

    Enum documents MUST be inserted before the Class document that references them
    (TerminusDB v12 requirement — foreign key enforcement at insert time).
    """
    self._validate_type_name(name)  # blocks reserved names
    enum_docs: list[dict[str, Any]] = []
    compiled_fields: dict[str, Any] = {}

    for field_name, field_spec in fields.items():
        compiled_fields[field_name] = self._compile_field_from_spec(
            field_spec, name, field_name, enum_docs
        )

    # Insert enums FIRST, then the class
    def _insert_sync():
        with self._client_lock:
            if enum_docs:
                self.client.insert_document(enum_docs, graph_type="schema",
                                             commit_msg=f"Add enums for {name}")
            class_doc = {
                "@type": "Class",
                "@id": name,
                "@key": self._build_key_strategy({"key_strategy": key_strategy}),
                **compiled_fields,
            }
            if description:
                class_doc["@documentation"] = {"@comment": description}
            self.client.insert_document(class_doc, graph_type="schema",
                                         commit_msg=f"Create type {name}")

    await asyncio.to_thread(_insert_sync)


async def update_schema_type(
    self,
    name: str,
    fields: dict[str, Any],
) -> None:
    """Replace a Class document in the TerminusDB schema graph.

    NOTE: replace_document is full-replacement. Field additions are safe.
    Field type changes with existing data may raise DatabaseError from TerminusDB
    (strengthening constraint violation) — catch and re-raise as ValueError.
    """
    enum_docs: list[dict[str, Any]] = []
    compiled_fields: dict[str, Any] = {}
    for field_name, field_spec in fields.items():
        compiled_fields[field_name] = self._compile_field_from_spec(
            field_spec, name, field_name, enum_docs
        )

    def _replace_sync():
        with self._client_lock:
            if enum_docs:
                # Use replace_document with create=True to upsert enum docs
                self.client.replace_document(enum_docs, graph_type="schema",
                                              create=True, commit_msg=f"Update enums for {name}")
            class_doc = {"@type": "Class", "@id": name, **compiled_fields}
            try:
                self.client.replace_document(class_doc, graph_type="schema",
                                              commit_msg=f"Update type {name}")
            except Exception as e:
                # TerminusDB returns constraint violation as DatabaseError
                raise ValueError(f"Schema update rejected by TerminusDB: {e}") from e

    await asyncio.to_thread(_replace_sync)


async def delete_schema_type(
    self,
    name: str,
) -> None:
    """Delete a Class and its Enum documents from schema graph.

    Raises ValueError if entities of this type exist.
    IMPORTANT: delete_document takes a string ID, not a dict.
    Enum cleanup: fetch class doc first to find referenced enum names.
    """
    # Count check happens in the route handler before calling this
    def _delete_sync():
        with self._client_lock:
            # Fetch class doc to identify associated enum IDs
            try:
                class_doc = self.client.get_document(name, graph_type="schema")
                enum_ids = [
                    v for v in class_doc.values()
                    if isinstance(v, str) and v.startswith(f"{name}_")
                ]
            except Exception:
                enum_ids = []

            # Delete class doc first (string ID, not dict)
            self.client.delete_document(name, graph_type="schema",
                                         commit_msg=f"Delete type {name}")
            # Then delete associated enum docs
            for enum_id in enum_ids:
                try:
                    self.client.delete_document(enum_id, graph_type="schema",
                                                 commit_msg=f"Delete enum {enum_id}")
                except Exception:
                    pass  # Enum may already be gone

    await asyncio.to_thread(_delete_sync)
```

**Helper method — `_compile_field_from_spec`:** Bridge from `FieldSpec` Pydantic model to `_compile_field()` signature:

```python
def _compile_field_from_spec(
    self,
    field_spec: "FieldSpec",
    class_name: str,
    field_name: str,
    enum_docs: list[dict[str, Any]],
) -> str | dict[str, Any]:
    """Convert FieldSpec Pydantic model to _compile_field() dict format."""
    from .schema_compiler import SchemaCompiler
    spec_dict = {
        "type": field_spec.type,
        "required": field_spec.required,
        "values": field_spec.values or [],
    }
    if field_spec.link_type:
        spec_dict["type"] = field_spec.link_type  # e.g. "Person"
    compiler = SchemaCompiler()
    return compiler._compile_field(spec_dict, class_name, field_name, enum_docs)
```

**Threading safety — add to `__init__`:**

```python
import threading

def __init__(self, vault_path: Path):
    ...
    self._client_lock = threading.Lock()
```

**Reserved name validation:**

```python
_RESERVED_TERMINUS_NAMES = frozenset({
    "Class", "Enum", "Set", "Optional", "TaggedUnion", "Array",
    "Sys", "xsd", "rdf", "owl", "rdfs",
})

def _validate_type_name(self, name: str) -> None:
    if name in self._RESERVED_TERMINUS_NAMES:
        raise ValueError(
            f"Type name '{name}' is reserved by TerminusDB and cannot be used."
        )
```

**Schema persistence (important — add to `connect()`):**

```python
async def connect(self, schemas: list[dict[str, Any]]) -> None:
    """Connect to TerminusDB and apply seed schemas.

    Seed schemas (from YAML) are additive only — they never overwrite
    or delete types already in TerminusDB. User-created types survive restarts.
    """
    ...
    # When syncing YAML schemas, only insert types that DON'T already exist:
    existing_types = {s["@id"] for s in existing_schema_docs}
    new_schemas = [s for s in schemas if s.get("@id") not in existing_types]
    if new_schemas:
        self.client.insert_document(new_schemas, graph_type="schema",
                                     commit_msg="Bootstrap seed schemas")
```

#### Research Insights — Phase 1 Backend

**TerminusDB Python client patterns (confirmed from docs):**

```python
# Schema insertion with raw dicts — the correct API
schema = [
    {"@type": "Enum", "@id": "Project_status", "@value": ["active", "paused"]},
    {"@type": "Class", "@id": "Project", "status": "Project_status"}
]
client.insert_document(schema, graph_type="schema", commit_msg="Add Project type")

# Correct delete_document call — string ID, not dict
client.delete_document("Project", graph_type="schema", commit_msg="Delete Project")

# Upsert for schema updates (create=True allows insert if not exists)
client.replace_document(schema_doc, graph_type="schema", create=True)

# allow_destructive_migration for strengthening changes
client.replace_document(schema_doc, graph_type="schema",
                        allow_destructive_migration=True)  # only when intentional
```

**N+1 performance — concurrent count queries:**

```python
# Replace N serial count queries with asyncio.gather()
# Converts O(N) sequential latency to O(1) parallel latency
async def list_schema_types_with_counts(self) -> list[dict]:
    schemas = await self.list_schemas()

    async def get_count(type_name: str) -> int:
        def _count():
            with self._client_lock:
                results = self.client.query_document({"@type": type_name}, count=100)
                return len(list(results))
        return await asyncio.to_thread(_count)

    counts = await asyncio.gather(*[get_count(s["name"]) for s in schemas])
    return [{**s, "entity_count": c} for s, c in zip(schemas, counts)]
    # Note: if len(schemas) > 20, skip counts and return entity_count=-1
    # Flutter shows "—" as the count to avoid too many concurrent connections
```

**Security — field type validation in `_compile_field_from_spec`:**

```python
ALLOWED_FIELD_TYPES = frozenset({
    "string", "integer", "boolean", "datetime", "enum", "link",
})

def _compile_field_from_spec(self, field_spec, class_name, field_name, enum_docs):
    if field_spec.type not in ALLOWED_FIELD_TYPES:
        raise ValueError(f"Unknown field type '{field_spec.type}'")
    # For link fields, validate link_type against existing schema types
    if field_spec.type == "link":
        if not field_spec.link_type:
            raise ValueError("link field requires link_type")
        if not re.match(r'^[A-Za-z][A-Za-z0-9_]*$', field_spec.link_type):
            raise ValueError(f"Invalid link_type '{field_spec.link_type}'")
```

#### 1.2 New Pydantic models

**File:** `computer/modules/brain/models.py`

```python
import re
from pydantic import BaseModel, Field, ConfigDict, field_validator

_TYPE_NAME_RE = re.compile(r'^[A-Za-z][A-Za-z0-9_]*$')
_FIELD_NAME_RE = re.compile(r'^[a-z][a-z0-9_]*$')
_RESERVED = frozenset({
    "Class", "Enum", "Set", "Optional", "TaggedUnion", "Array",
    "Sys", "xsd", "rdf", "owl", "rdfs",
})

class FieldSpec(BaseModel):
    model_config = ConfigDict(strict=True, validate_assignment=True)

    type: str = Field(description="string | integer | boolean | datetime | enum | link")
    required: bool = False
    values: list[str] | None = None   # for enum only — must have >= 1 item
    link_type: str | None = None      # for link fields — must match ^[A-Za-z][A-Za-z0-9_]*$
    description: str | None = None

    @field_validator("type")
    @classmethod
    def validate_type(cls, v: str) -> str:
        allowed = {"string", "integer", "boolean", "datetime", "enum", "link"}
        if v not in allowed:
            raise ValueError(f"type must be one of {allowed}, got '{v}'")
        return v

    @field_validator("values")
    @classmethod
    def validate_values(cls, v, info):
        if info.data.get("type") == "enum" and not v:
            raise ValueError("enum field requires at least one value in 'values'")
        return v

    @field_validator("link_type")
    @classmethod
    def validate_link_type(cls, v):
        if v is not None and not _TYPE_NAME_RE.match(v):
            raise ValueError(f"link_type must match [A-Za-z][A-Za-z0-9_]*, got '{v}'")
        return v


class CreateSchemaTypeRequest(BaseModel):
    model_config = ConfigDict(strict=True)

    name: str = Field(description="PascalCase type name, e.g. 'Project'")
    fields: dict[str, FieldSpec]
    key_strategy: str = "Random"
    description: str | None = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, v: str) -> str:
        if not _TYPE_NAME_RE.match(v):
            raise ValueError(f"Type name must match ^[A-Za-z][A-Za-z0-9_]*$, got '{v}'")
        if v in _RESERVED:
            raise ValueError(f"'{v}' is a reserved TerminusDB name")
        return v

    @field_validator("fields")
    @classmethod
    def validate_field_names(cls, v: dict) -> dict:
        for name in v:
            if not _FIELD_NAME_RE.match(name):
                raise ValueError(
                    f"Field name '{name}' must match ^[a-z][a-z0-9_]*$"
                )
        return v


class UpdateSchemaTypeRequest(BaseModel):
    model_config = ConfigDict(strict=True)

    fields: dict[str, FieldSpec]  # full replacement of field map

    @field_validator("fields")
    @classmethod
    def validate_field_names(cls, v: dict) -> dict:
        for name in v:
            if not _FIELD_NAME_RE.match(name):
                raise ValueError(f"Field name '{name}' must match ^[a-z][a-z0-9_]*$")
        return v


class SchemaTypeResponse(BaseModel):
    name: str
    description: str | None
    key_strategy: str
    fields: list[dict[str, Any]]      # matches existing BrainField JSON shape
    entity_count: int                 # -1 means "not fetched" (>20 types)


class SavedQueryModel(BaseModel):
    """Stored in vault/.brain/queries.json via backend API (NOT direct Flutter file I/O)."""
    id: str
    name: str
    entity_type: str
    filters: list[dict[str, Any]]


class SavedQueryListResponse(BaseModel):
    queries: list[SavedQueryModel]
```

#### 1.3 New FastAPI routes

**File:** `computer/modules/brain/module.py`

**Route namespace correction:** Use `/types` not `/schema/types` — consistent with existing `/entities` pattern.

```python
# GET /api/brain/types — list all types with fields + entity counts
# POST /api/brain/types — create new type
# PUT /api/brain/types/{type_name} — update type (full field replacement)
# DELETE /api/brain/types/{type_name} — delete type (blocked if entities exist)

# Saved query routes (new — Flutter must NOT write vault/.brain/ directly)
# GET  /api/brain/queries — list saved queries
# POST /api/brain/queries — save a query
# DELETE /api/brain/queries/{query_id} — delete a query
```

Route implementation highlights:

```python
@router.get("/types", response_model=list[SchemaTypeResponse])
async def list_schema_types(brain: BrainModule = Depends(get_brain)):
    kg = await brain._ensure_kg_service()
    return await kg.list_schema_types_with_counts()  # concurrent gather

@router.post("/types", response_model=dict)
async def create_schema_type(
    request: CreateSchemaTypeRequest,
    brain: BrainModule = Depends(get_brain),
):
    kg = await brain._ensure_kg_service()
    try:
        await kg.create_schema_type(
            name=request.name,
            fields={k: v.model_dump() for k, v in request.fields.items()},
            key_strategy=request.key_strategy,
            description=request.description,
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return {"success": True, "name": request.name}

@router.delete("/types/{type_name}")
async def delete_schema_type(
    type_name: str,
    brain: BrainModule = Depends(get_brain),
):
    # Validate name first (avoid TerminusDB errors from injection)
    if not re.match(r'^[A-Za-z][A-Za-z0-9_]*$', type_name):
        raise HTTPException(status_code=400, detail="Invalid type name")
    kg = await brain._ensure_kg_service()
    # TOCTOU note: check + delete is not atomic, but schema ops are rare
    # and TerminusDB will error if entities exist at delete time anyway
    count = await kg.count_entities(type_name)
    if count > 0:
        raise HTTPException(
            status_code=400,
            detail=f"Type has {count} entities. Delete all entities first."
        )
    await kg.delete_schema_type(type_name)
    return {"success": True}

# Saved queries — server-side, not Flutter direct file I/O
_queries_lock = asyncio.Lock()  # module-level lock for queries.json

@router.get("/queries", response_model=SavedQueryListResponse)
async def list_saved_queries(brain: BrainModule = Depends(get_brain)):
    queries_path = brain.vault_path / ".brain" / "queries.json"
    async with _queries_lock:
        if queries_path.exists():
            import json
            data = json.loads(queries_path.read_text())
            return SavedQueryListResponse(**data)
    return SavedQueryListResponse(queries=[])

@router.post("/queries", response_model=dict)
async def save_query(
    request: SavedQueryModel,
    brain: BrainModule = Depends(get_brain),
):
    queries_path = brain.vault_path / ".brain" / "queries.json"
    async with _queries_lock:
        import json, uuid
        data = json.loads(queries_path.read_text()) if queries_path.exists() else {"queries": []}
        request_dict = request.model_dump()
        request_dict["id"] = request_dict.get("id") or str(uuid.uuid4())
        data["queries"].append(request_dict)
        queries_path.write_text(json.dumps(data, indent=2))
    return {"success": True, "id": request_dict["id"]}
```

#### 1.4 New MCP tools (agent parity)

**File:** `computer/modules/brain/mcp_tools.py`

Add 7 new tools so agents have full parity with the UI:

| Tool | Args | Notes |
|------|------|-------|
| `brain_create_type` | `name`, `fields` (JSON with enum), `key_strategy?`, `description?` | fields validated via FieldSpec |
| `brain_update_type` | `name`, `fields` (JSON) | full field replacement |
| `brain_delete_type` | `name` | blocked if entities exist |
| `brain_list_types` | — | returns types + counts (replaces `brain_list_schemas` raw format) |
| `brain_list_saved_queries` | — | returns all saved queries |
| `brain_save_query` | `name`, `entity_type`, `filters` | saves named filter set |
| `brain_delete_saved_query` | `query_id` | removes saved query |

**MCP tool input schema must be explicit for field types (not raw JSON string):**

```python
"fields": {
    "type": "object",
    "description": "Field definitions keyed by snake_case field name",
    "additionalProperties": {
        "type": "object",
        "properties": {
            "type": {
                "type": "string",
                "enum": ["string", "integer", "boolean", "datetime", "enum", "link"]
            },
            "required": {"type": "boolean"},
            "values": {"type": "array", "items": {"type": "string"}},
            "link_type": {"type": "string", "description": "Target type name for link fields"},
            "description": {"type": "string"}
        },
        "required": ["type"]
    }
}
```

**`brain_list_schemas` normalization (existing tool):** Update `brain_list_schemas` to return normalized `{name, fields, entity_count}` format — currently returns raw TerminusDB format which breaks agent workflows.

**Acceptance criteria — Phase 1:**
- [ ] `GET /api/brain/types` returns all types with field shapes and entity counts
- [ ] `POST /api/brain/types` creates a new TerminusDB class; new type appears in schema list
- [ ] `PUT /api/brain/types/Project` replaces field definitions; existing entities unaffected for additive changes
- [ ] `DELETE /api/brain/types/Project` returns 400 if entities exist; succeeds when none
- [ ] User-created types survive server restart (connect() is additive-only)
- [ ] Reserved names (`Class`, `Enum`, etc.) return 400, not 500
- [ ] All 7 MCP tools work (3 schema + 4 query management)
- [ ] `GET /api/brain/queries`, `POST /api/brain/queries`, `DELETE /api/brain/queries/{id}` functional
- [ ] `brain_list_schemas` returns normalized format

---

### Phase 2: Flutter — Adaptive Sidebar Layout

**Goal:** Replace the `TabBar` home screen with an adaptive 3-pane layout. Types become a persistent sidebar column, not tabs.

#### 2.1 New `BrainTypeSidebar` widget

**File:** `app/lib/features/brain/widgets/brain_type_sidebar.dart`

```
┌──────────────────┐
│ Types            │
│ ─────────────── │
│ • Project    12  │ ← tap → select type (& open type manager on long press)
│ • Person      8  │
│ • Task        4  │
│ ─────────────── │
│ + New Type       │ ← opens BrainTypeManagerSheet(isNew: true)
└──────────────────┘
```

- `ConsumerWidget`, reads `brainSchemaDetailProvider` and `brainSelectedTypeProvider`
- Each row: `InkWell` with type name + entity count on the right
- Selected row: `BrandColors.forestMist` background, `BrandColors.forest` text
- Long-press on type name → opens `BrainTypeManagerSheet(typeName: name)`
- Width: 180px (fixed `SizedBox`)
- Vertical divider: `BrandColors.nightTextSecondary.withValues(alpha: 0.2)`, 1px

#### Research Insights — Sidebar Performance

**Use `select()` to prevent O(N) rebuilds on type switch:**

```dart
// Each type row watches only its own selection state
// → O(1) rebuilds per type switch instead of O(N)
class _TypeRow extends ConsumerWidget {
  final BrainSchemaDetail schema;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSelected = ref.watch(
      brainSelectedTypeProvider.select((t) => t == schema.name)
    );
    // Only rebuilds when THIS row's selection changes
    return ListTile(
      selected: isSelected,
      title: Text(schema.name),
      trailing: Text('${schema.entityCount}'),
      onTap: () => ref.read(brainSelectedTypeProvider.notifier).state = schema.name,
      onLongPress: () => _openTypeManager(context),
    );
  }
}
```

#### 2.2 New `BrainHomeScreen` with adaptive layout

**File:** `app/lib/features/brain/screens/brain_home_screen.dart` (replace existing)

**Critical pattern: `LayoutBuilder` only decides wide vs. narrow. Entity state goes in `_BrainWideLayout`:**

```dart
// BrainLayoutMode enum — cleaner than bool, enables animated transitions
enum BrainLayoutMode { mobile, wide }

// Derived provider — avoids recomputing on every LayoutBuilder rebuild
final brainLayoutModeProvider = Provider<BrainLayoutMode>((ref) {
  // Note: this is set from the LayoutBuilder callback via a StateProvider
  return ref.watch(_brainLayoutModeStateProvider);
});
final _brainLayoutModeStateProvider = StateProvider<BrainLayoutMode>(
    (ref) => BrainLayoutMode.mobile);

class BrainHomeScreen extends ConsumerWidget {
  const BrainHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // ONLY layout decision here — no entity or schema state
        final mode = constraints.maxWidth >= 800
            ? BrainLayoutMode.wide
            : BrainLayoutMode.mobile;

        // Update mode provider after frame (avoid setState during build)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (ref.read(_brainLayoutModeStateProvider) != mode) {
            ref.read(_brainLayoutModeStateProvider.notifier).state = mode;
          }
        });

        return mode == BrainLayoutMode.wide
            ? const _BrainWideLayout()   // const: no rebuild on entity selection
            : const _BrainMobileLayout();
      },
    );
  }
}

// _BrainWideLayout is a ConsumerWidget — it reads entity selection state
class _BrainWideLayout extends ConsumerWidget {
  const _BrainWideLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedEntityId = ref.watch(brainSelectedEntityProvider);

    return Row(
      children: [
        const SizedBox(width: 180, child: BrainTypeSidebar()),
        const VerticalDivider(width: 1),
        const Expanded(child: BrainEntityListPanel()),
        if (selectedEntityId != null) ...[
          const VerticalDivider(width: 1),
          // AnimatedSize for smooth detail pane open/close
          // (NOT AnimatedContainer — that causes Row reflow on every frame)
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: SizedBox(
              width: 360,
              child: BrainEntityDetailPane(entityId: selectedEntityId),
            ),
          ),
        ],
      ],
    );
  }
}
```

**Mobile layout (`_BrainMobileLayout`):**
- Standard `Scaffold` with `Drawer` containing `BrainTypeSidebar`
- Drawer icon in AppBar
- Entity list takes full width
- Tapping entity card pushes `BrainEntityDetailScreen` (existing full-screen screen)

**Wide layout (`BrainEntityListPanel`):**
- Thin wrapper around `BrainEntityListScreen` (no Scaffold — embedded)
- AppBar replaced with a simple header row: type name + entity count + `[+ New]` button
- `[+ New]` FAB → `BrainEntityFormScreen` (existing form)

**Wide layout (`BrainEntityDetailPane`):**
- Thin wrapper that renders `BrainEntityDetailScreen` content without Scaffold/AppBar
- "Close" icon button top-right → clears `brainSelectedEntityProvider`

#### 2.3 New providers

**File:** `app/lib/features/brain/providers/brain_ui_state_provider.dart` (extend)

```dart
// Selected entity IRI for the inline detail pane (wide layout only)
final brainSelectedEntityProvider = StateProvider<String?>((ref) => null);

// Schema types endpoint result — richer than current brainSchemaListProvider
// Includes entity_count per type. Use this instead of brainSchemaListProvider
// for the sidebar (which needs counts). brainSchemaListProvider can be deprecated.
final brainSchemaDetailProvider = FutureProvider.autoDispose<List<BrainSchemaDetail>>(
  (ref) => ref.read(brainServiceProvider).listSchemaTypes(),
);

// Active filter conditions for the current type
// NotifierProvider (not StateProvider<List>) — enables atomic mutation methods
final brainActiveFiltersProvider =
    NotifierProvider<BrainFilterNotifier, List<BrainFilterCondition>>(
      BrainFilterNotifier.new,
    );

class BrainFilterNotifier extends Notifier<List<BrainFilterCondition>> {
  @override
  List<BrainFilterCondition> build() => [];

  void add(BrainFilterCondition condition) =>
      state = [...state, condition];

  void remove(int index) =>
      state = [...state]..removeAt(index);

  void clear() => state = [];
}
```

**Invalidation strategy (important):**
- Entity CRUD (create/delete entity): `ref.invalidate(brainEntityListProvider)` only — do NOT invalidate `brainSchemaDetailProvider`
- Schema mutations (create/update/delete type): `ref.invalidate(brainSchemaDetailProvider)` — entity counts in sidebar update
- Accept that sidebar counts are "last-fetched" between entity CRUD operations

**Acceptance criteria — Phase 2:**
- [ ] Wide (≥800px): sidebar visible with all types + counts; selecting a type updates card list
- [ ] Wide: tapping a card opens the inline detail pane (AnimatedSize) without nav push; `×` closes it
- [ ] Narrow (<800px): sidebar accessible via Drawer; tapping card pushes detail screen
- [ ] `LayoutBuilder` callback only evaluates width breakpoint — no entity/schema state reads
- [ ] `+ New Type` button in sidebar opens `BrainTypeManagerSheet` in new-type mode
- [ ] `+ New` button in list header opens `BrainEntityFormScreen` for selected type
- [ ] Filters clear when switching types (filter state scoped to type)

---

### Phase 3: Flutter — Type Manager Sheet

**Goal:** Let users create and edit type schemas from within the app. Writes to the Phase 1 backend endpoints.

**File:** `app/lib/features/brain/widgets/brain_type_manager_sheet.dart`

Two modes: **new type** (blank form) and **edit type** (pre-filled from current schema).

```
┌─────────────────────────────────────┐
│  Type: Project              [Delete]│
│  ──────────────────────────────────│
│  Fields                             │
│  ┌───────────────────────────────┐  │
│  │ name         string  required │  │
│  │ status       enum   ┌───────┐ │  │
│  │              values:│active │ │  │
│  │                     │paused │ │  │
│  │                     └───────┘ │  │
│  │ team_members  link:Person     │  │
│  └───────────────────────────────┘  │
│  [+ Add field]                      │
│                                     │
│           [Cancel]   [Save]         │
└─────────────────────────────────────┘
```

**Must be `ConsumerStatefulWidget`** (not `StatefulWidget`) — needs `ref` for provider reads during form validation (e.g., checking existing type names from `brainSchemaDetailProvider`).

```dart
class BrainTypeManagerSheet extends ConsumerStatefulWidget {
  final String? typeName;  // null = new type mode
  const BrainTypeManagerSheet({this.typeName, super.key});

  @override
  ConsumerState<BrainTypeManagerSheet> createState() =>
      _BrainTypeManagerSheetState();
}
```

#### Field editor row

Each field row has:
- `TextFormField` for field name (validated: `^[a-z][a-z0-9_]*$`)
- `DropdownButton<String>` for field type: `string | integer | boolean | datetime | enum | link`
- Required toggle (`Switch`)
- If `enum`: expandable area to add/remove enum values (chip input)
- If `link`: `DropdownButton` populated from `brainSchemaDetailProvider` (pick which type to link to)
- Delete icon (removes field from local state; committed on Save)

**All `TextEditingController` instances must be in `State` (not `build()`) and disposed in `dispose()`.**

#### Save logic

On **Save**:
1. Validate all field names are non-empty and unique (`^[a-z][a-z0-9_]*$`)
2. Validate type name (`^[A-Za-z][A-Za-z0-9_]*$`, not reserved)
3. Build `UpdateSchemaTypeRequest` / `CreateSchemaTypeRequest` from form state
4. `POST /api/brain/types` (new) or `PUT /api/brain/types/{name}` (edit)
5. On success: `ref.invalidate(brainSchemaDetailProvider)`; close sheet
6. On error (400 from backend): show inline error text (don't close sheet)

**Handle schema strengthening errors:** If `PUT` returns 400 with TerminusDB constraint message, show: _"Cannot make field '{name}' required while data exists. Remove existing data first."_

#### Delete logic

`[Delete]` button → `AlertDialog`:
- If entity count > 0: "Delete all N entities first. This type cannot be removed while data exists."
- If entity count = 0: "Delete type Project? This cannot be undone." → confirm → `DELETE /api/brain/types/{name}` → invalidate providers → close sheet

**Acceptance criteria — Phase 3:**
- [ ] Tapping `+ New Type` opens sheet with blank name field and no fields
- [ ] Can add fields of each supported type: `string`, `integer`, `boolean`, `datetime`, `enum`, `link`
- [ ] `enum` fields show chip input for values (add/remove individual values)
- [ ] `link` fields show dropdown populated with existing type names
- [ ] Saving a new type calls `POST /api/brain/types` and new type appears in sidebar
- [ ] Editing an existing type calls `PUT /api/brain/types/{name}`; existing entities unaffected for additive changes
- [ ] Delete blocked with clear message if entities exist; succeeds when none
- [ ] Schema strengthening errors shown inline (not dismissed)
- [ ] Validation: field names must be `^[a-z][a-z0-9_]*$`, type name `^[A-Za-z][A-Za-z0-9_]*$`
- [ ] Reserved names (`Class`, `Enum`, etc.) rejected with user-friendly message before API call

---

### Phase 4: Flutter — Query Builder

**Goal:** A filter bar above the entity list that lets users build WHERE-style filter conditions. Visual mode only for v1; NL-to-filter deferred.

**File:** `app/lib/features/brain/widgets/brain_query_bar.dart`

```
[status = active  ×]  [people ∋ @kevin  ×]  [+ Add filter]  [Saved ▾]
```

#### Filter condition model

```dart
// Sealed class FilterValue — type-safe, no dynamic
sealed class FilterValue {
  const FilterValue();
}
class StringFilterValue extends FilterValue {
  final String value;
  const StringFilterValue(this.value);
}
class EnumFilterValue extends FilterValue {
  final String value;
  const EnumFilterValue(this.value);
}
class LinkFilterValue extends FilterValue {
  final String entityId;  // entity IRI
  const LinkFilterValue(this.entityId);
}

class BrainFilterCondition {
  final String fieldName;
  final String operator;   // eq | neq | contains (v1 only — drop gt/lt/exists)
  final FilterValue value;

  const BrainFilterCondition({
    required this.fieldName,
    required this.operator,
    required this.value,
  });
}

// In BrainQueryBar widget:
// Use ValueKey for correct chip reconciliation on remove
Wrap(
  children: [
    for (final (index, condition) in filters.indexed)
      ValueKey('${condition.fieldName}-${condition.operator}-${condition.value}')
      // ... filter chip
  ],
)
```

**Operator set for v1 (trimmed from original plan):** `eq`, `neq`, `contains` — drop `gt`, `lt`, `exists` (no v1 use case).

**Filters scoped to type:** When `brainSelectedTypeProvider` changes, call `ref.read(brainActiveFiltersProvider.notifier).clear()`.

#### `[+ Add filter]` flow

Opens a small bottom sheet with:
1. Field picker: `DropdownButton` from current type's schema fields
2. Operator picker: `eq` / `neq` for enum; `eq` / `contains` for string; `eq` for link
3. Value input: appropriate widget for field type
4. `[Apply]` → calls `ref.read(brainActiveFiltersProvider.notifier).add(condition)`

#### Filter application (client-side v1)

`BrainEntityListScreen` reads `brainActiveFiltersProvider` and applies filters to the loaded entity list locally (same pattern as existing search debounce). Client-side filtering is O(N*F) where N=entities, F=fields checked — safe at `limit: 100`.

**Add comment tying client-side approach to the limit guard:**
```dart
// Client-side filter is O(N * fields). Safe at limit=100 (current cap).
// Move to server-side WOQL WHERE filters if limit is raised above 500.
```

#### Saved queries

**Storage: backend HTTP endpoints** (not Flutter direct file I/O — see Enhancement Summary).

`BrainQueryService` in Flutter is a thin HTTP client:

```dart
class BrainQueryService {
  final BrainService _brain;
  BrainQueryService(this._brain);

  Future<List<SavedQuery>> loadQueries() =>
      _brain.get('/queries').then(SavedQueryListResponse.fromJson).then((r) => r.queries);

  Future<String> saveQuery(String name, String type, List<BrainFilterCondition> filters) =>
      _brain.post('/queries', body: {
        'name': name, 'entity_type': type,
        'filters': filters.map(_conditionToJson).toList(),
      }).then((r) => r['id'] as String);

  Future<void> deleteQuery(String id) => _brain.delete('/queries/$id');
}
```

`[Saved ▾]` button → `DropdownMenu` listing saved queries + `[Save current]` entry. Selecting a query populates `brainSelectedTypeProvider` + `brainActiveFiltersProvider`.

**Filter format normalization:** When loading saved queries, parse filter JSON back to typed `BrainFilterCondition` list (not raw `dynamic`).

**Acceptance criteria — Phase 4:**
- [ ] Filter bar visible above card list (hidden when no filters; `[+ Add filter]` always visible)
- [ ] Adding a filter via bottom sheet creates a chip in the bar; card list immediately filters
- [ ] Multiple filters combine with AND logic
- [ ] `×` on a filter chip removes it (correct `ValueKey` reconciliation)
- [ ] Filters clear when switching types
- [ ] Saved queries load from `GET /api/brain/queries`; save via `POST /api/brain/queries`
- [ ] `BrainQueryService` uses HTTP, not direct vault file I/O
- [ ] MCP tools `brain_list_saved_queries`, `brain_save_query`, `brain_delete_saved_query` work

---

## File Change Summary

### Backend (`computer/modules/brain/`)

| File | Change |
|------|--------|
| `knowledge_graph.py` | +3 methods: `create_schema_type`, `update_schema_type`, `delete_schema_type`; +`list_schema_types_with_counts()`; +`threading.Lock`; +`_validate_type_name()`; +`_compile_field_from_spec()` |
| `models.py` | +`FieldSpec`, `CreateSchemaTypeRequest`, `UpdateSchemaTypeRequest`, `SchemaTypeResponse`, `SavedQueryModel`, `SavedQueryListResponse` |
| `module.py` | +4 type routes (`GET/POST /types`, `PUT/DELETE /types/{name}`); +3 query routes (`GET/POST /queries`, `DELETE /queries/{id}`) |
| `mcp_tools.py` | +7 tools: `brain_create_type`, `brain_update_type`, `brain_delete_type`, `brain_list_types`, `brain_list_saved_queries`, `brain_save_query`, `brain_delete_saved_query`; fix `brain_list_schemas` output format |

### Flutter (`app/lib/features/brain/`)

| File | Change |
|------|--------|
| `screens/brain_home_screen.dart` | **Replace** TabBar layout with adaptive sidebar + split-pane; `BrainLayoutMode` enum; `_BrainWideLayout`/`_BrainMobileLayout` as `const ConsumerWidget`s |
| `services/brain_service.dart` | +7 methods: `listSchemaTypes`, `createSchemaType`, `updateSchemaType`, `deleteSchemaType`, `listSavedQueries`, `saveQuery`, `deleteQuery` — all calling `/api/brain/types` or `/api/brain/queries` |
| `providers/brain_ui_state_provider.dart` | +`brainSelectedEntityProvider`, +`brainActiveFiltersProvider` (NotifierProvider), +`brainSchemaDetailProvider`, +`_brainLayoutModeStateProvider` |
| `widgets/brain_type_sidebar.dart` | **New** — `ConsumerWidget`, per-row `select()` |
| `widgets/brain_type_manager_sheet.dart` | **New** — `ConsumerStatefulWidget` |
| `widgets/brain_query_bar.dart` | **New** — `ValueKey` on chips, sealed `FilterValue` |
| `services/brain_query_service.dart` | **New** — thin HTTP client (NOT vault file I/O) |
| `models/brain_filter.dart` | **New** — `BrainFilterCondition`, `FilterValue` sealed class, `SavedQuery` |
| `screens/brain_entity_list_screen.dart` | Adapt to work without Scaffold (embedded in split pane); accept `brainActiveFiltersProvider`; add client-side filter comment |
| `screens/brain_entity_detail_screen.dart` | Adapt to render without AppBar as inline pane (new `embedded:` param) |

---

## Acceptance Criteria

### Functional

- [ ] Sidebar lists all types with live entity counts
- [ ] Selecting a type in sidebar updates the card list (no page push)
- [ ] On wide screens: tapping a card opens inline detail pane (AnimatedSize); `×` closes it
- [ ] On mobile: sidebar in Drawer; card tap pushes full detail screen
- [ ] `+ New Type` in sidebar opens type manager sheet; created type appears immediately
- [ ] Long-pressing a type opens type manager in edit mode
- [ ] Can add `string`, `integer`, `boolean`, `datetime`, `enum`, `link` fields to a type
- [ ] Enum fields require at least 1 value before saving
- [ ] Link fields pick from existing type names
- [ ] Type deletion blocked with count message if entities exist
- [ ] Filter bar: add/remove filter conditions (`eq`, `neq`, `contains`); list filters in real time
- [ ] Saved queries: save + reload named queries via HTTP endpoints
- [ ] Existing entity CRUD (create, edit, delete) still works unchanged
- [ ] User-created types survive server restart

### Non-Functional

- [ ] Sidebar type switch < 100ms (existing cached data)
- [ ] Type manager sheet opens < 200ms
- [ ] `GET /api/brain/types` < 200ms for ≤ 20 types (concurrent gather)
- [ ] No hardcoded colors — use `BrandColors` tokens only
- [ ] `LayoutBuilder` callback only evaluates width (no entity/schema state reads)
- [ ] `_BrainWideLayout` is a `const ConsumerWidget` — sidebar/list do not rebuild on entity tap
- [ ] All `TextEditingController` instances disposed in `dispose()`
- [ ] `ref.listen` only inside `build()` — never in `initState`
- [ ] `BrainQueryService` uses HTTP endpoints, not direct vault file I/O
- [ ] Reserved TerminusDB names blocked at API and UI validation layers
- [ ] `WOQLClient` access serialized via `threading.Lock`
- [ ] Follows `app/CLAUDE.md` and `computer/CLAUDE.md` conventions throughout

---

## Sequence / Suggested Order

```
Phase 1 (backend)  ──→  Phase 2 (layout)  ──→  Phase 3 (type manager)  ──→  Phase 4 (query)
  can be done               depends on                 depends on                depends on
  independently             Phase 1 for                Phase 1 types +           Phase 2
                            type counts                Phase 2 for layout
```

Phase 1 and the shell of Phase 2 can run in parallel. The type manager (Phase 3) needs the Phase 1 `/api/brain/types` endpoints working. The query builder (Phase 4) needs the new card list layout from Phase 2 and the query endpoints from Phase 1.

---

## Open Questions (resolved for planning)

| Question | Decision |
|----------|----------|
| Saved query storage | Backend HTTP endpoints (`/api/brain/queries`) + `vault/.brain/queries.json` server-side — not Flutter direct file I/O |
| Schema deletion with entities | Hard block with count message — safest for v1 |
| NL-to-filter query | Deferred — visual filter builder only for v1 |
| Mobile sidebar | Drawer — same pattern as other modules |
| Field types for v1 | `string`, `integer`, `boolean`, `datetime`, `enum`, `link` — defer `array`, `computed` |
| Filter operators for v1 | `eq`, `neq`, `contains` — drop `gt`, `lt`, `exists` (YAGNI) |
| Route namespace | `/api/brain/types` (not `/api/brain/schema/types`) — consistent with `/api/brain/entities` |
| Schema mutation trust | MCP-only for schema mutations is ideal; HTTP routes also exposed for Flutter but should add trust guard before multi-user deployment |
| YAML + TerminusDB drift | `connect()` is additive-only — YAML seeds defaults, TerminusDB is authority |

---

## Additional Implementation Notes (from spec flow analysis)

These gaps were surfaced by spec flow analysis and must be addressed during implementation.

### Backend

**Schema cache invalidation** — `BrainModule.self.schemas` is an in-memory list loaded at startup. After any schema mutation via the new endpoints, this cache becomes stale. The existing `GET /api/brain/schemas` endpoint reads from `self.schemas`. Fix: add `await brain._reload_schemas()` at the end of each schema mutation route handler. This method calls `await kg.list_schemas()` and updates `self.schemas`.

**Batch enum deletion** — `delete_document` accepts a list of IDs, so the enum cleanup for `delete_schema_type` is efficient:
```python
# Delete class + all its enums in a single call
ids_to_delete = [name] + [f"{name}_{field}" for field in enum_field_names]
self.client.delete_document(ids_to_delete, graph_type="schema", commit_msg=f"Delete type {name}")
```

**Orphaned saved queries on type deletion** — after `DELETE /api/brain/types/{name}` succeeds, also purge saved queries for that type from `queries.json`:
```python
# In the delete_schema_type route handler, after kg.delete_schema_type():
async with _queries_lock:
    if queries_path.exists():
        data = json.loads(queries_path.read_text())
        data["queries"] = [q for q in data["queries"] if q["entity_type"] != type_name]
        queries_path.write_text(json.dumps(data, indent=2))
```

### Flutter

**`BrainSchemaDetail` model** — must be defined before Phase 2:
```dart
// In app/lib/features/brain/models/brain_schema.dart
class BrainSchemaDetail {
  final String name;
  final String? description;
  final List<BrainField> fields;
  final int entityCount;  // -1 = not fetched (> 20 types)

  const BrainSchemaDetail({required this.name, this.description,
      required this.fields, required this.entityCount});

  factory BrainSchemaDetail.fromJson(Map<String, dynamic> json) => BrainSchemaDetail(
    name: json['name'] as String,
    description: json['description'] as String?,
    fields: (json['fields'] as List).map((f) => BrainField.fromJson(f)).toList(),
    entityCount: json['entity_count'] as int? ?? -1,
  );
}
```

**Clear state on type switch** — when `brainSelectedTypeProvider` changes, clear both entity selection and search:
```dart
// In BrainHomeScreen or BrainEntityListPanel — listen to type changes
ref.listen(brainSelectedTypeProvider, (previous, next) {
  if (previous != next) {
    ref.read(brainSelectedEntityProvider.notifier).state = null;
    ref.read(brainActiveFiltersProvider.notifier).clear();
    ref.read(brainSearchQueryProvider.notifier).state = '';
  }
});
```

**Type name disabled in edit mode** — the type name field must be non-editable in `BrainTypeManagerSheet` when `typeName != null`:
```dart
TextFormField(
  initialValue: widget.typeName ?? '',
  enabled: widget.typeName == null,  // read-only in edit mode
  decoration: InputDecoration(
    labelText: 'Type name',
    helperText: widget.typeName != null
        ? 'Type name cannot be changed after creation'
        : null,
  ),
)
```

**`_isSubmitting` guard on type manager** — prevent double-tap on Save:
```dart
bool _isSubmitting = false;

Future<void> _handleSave() async {
  if (_isSubmitting) return;
  setState(() => _isSubmitting = true);
  try {
    // ... POST or PUT call
  } finally {
    if (mounted) setState(() => _isSubmitting = false);
  }
}
```

**`BrainTypeManagerSheet` scroll constraint** — per `app/CLAUDE.md` bottom sheet pattern:
```dart
DraggableScrollableSheet(
  maxChildSize: 0.85,
  builder: (context, scrollController) => Column(
    children: [
      // Drag handle (pinned)
      Flexible(
        child: SingleChildScrollView(
          controller: scrollController,
          child: _buildFieldList(),
        ),
      ),
      // Action buttons (pinned)
      _buildActionButtons(),
    ],
  ),
)
```

**Drawer closes on type selection** — in `_BrainMobileLayout`, the type sidebar row tap must close the Drawer:
```dart
onTap: () {
  ref.read(brainSelectedTypeProvider.notifier).state = schema.name;
  Navigator.of(context).pop();  // close Drawer
},
```

**Entity list tap conditional for wide vs mobile** — `BrainEntityListScreen` needs to know layout mode:
```dart
// In BrainEntityListScreen._onEntityTap()
final mode = ref.read(brainLayoutModeProvider);
if (mode == BrainLayoutMode.wide) {
  ref.read(brainSelectedEntityProvider.notifier).state = entity.id;
} else {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => BrainEntityDetailScreen(entityId: entity.id),
  ));
}
```

**Embedded detail pane delete** — `BrainEntityDetailPane` must intercept the delete callback. Pass `onDeleted` callback:
```dart
// BrainEntityDetailPane passes onDeleted to BrainEntityDetailScreen
BrainEntityDetailScreen(
  entityId: entityId,
  embedded: true,
  onDeleted: () => ref.read(brainSelectedEntityProvider.notifier).state = null,
)
// BrainEntityDetailScreen in embedded mode calls onDeleted() instead of Navigator.pop()
```

**Sidebar type name overflow** — prevent long type names from spilling:
```dart
Text(
  schema.name,
  overflow: TextOverflow.ellipsis,
  maxLines: 1,
)
```

**Sidebar must be scrollable**:
```dart
Expanded(
  child: ListView.builder(
    itemCount: schemas.length,
    itemBuilder: (context, i) => _TypeRow(schema: schemas[i]),
  ),
)
```

---

## Out of Scope

- Natural language query translation (NL → filter conditions)
- Daily–Brain integration
- Offline mode / file-based schema backup
- Graph visualization
- Type inheritance (`@inherits`)
- Bulk operations (multi-select)
- Cross-type search
- Server-side filter execution (WOQL) — client-side filtering at `limit: 100` is fine for v1

---

## References

### Key Files

| File | Purpose |
|------|---------|
| `app/lib/features/brain/screens/brain_home_screen.dart` | Current TabBar layout to replace |
| `app/lib/features/brain/screens/brain_entity_list_screen.dart` | List screen to adapt |
| `app/lib/features/brain/screens/brain_entity_detail_screen.dart` | Detail screen to embed |
| `app/lib/features/brain/models/brain_schema.dart` | Schema model (`BrainSchema`, `BrainField`) |
| `app/lib/features/brain/services/brain_service.dart` | HTTP service to extend |
| `app/lib/features/chat/screens/chat_shell.dart` | Adaptive layout pattern to copy |
| `computer/modules/brain/knowledge_graph.py` | TerminusDB service to extend |
| `computer/modules/brain/module.py` | FastAPI routes to extend |
| `computer/modules/brain/schema_compiler.py` | `_compile_field()` to reuse (note 4-arg signature) |
| `app/lib/core/theme/design_tokens.dart` | `BrandColors`, `Spacing`, `Radii` |

### Related Issues

- #94 — TerminusDB backend (complete, foundation for this)
- #98 — Tab-based Brain UI (complete, superseded by this)
