---
title: Brain System Redesign — Graph IS the Brain
type: refactor
date: 2026-03-05
issue: 200
---

# Brain System Redesign: Graph IS the Brain

The brain IS the Kuzu graph — sessions and notes are memory. This plan aligns naming, kills dead
code, adds agent-accessible Cypher tools, and redesigns the Brain tab as a memory navigator.

## Acceptance Criteria

- [x] `vault/.modules/brain/` deleted; no TerminusDB references remain
- [x] `GraphService` → `BrainService` throughout backend; `/api/graph/` → `/api/brain/`
- [x] `GraphService` → `BrainService` in Flutter; all API calls updated
- [x] MCP tools renamed to `brain_*` prefix; `brain_query` and `brain_execute` added
- [x] Brain tab shows unified memory feed (sessions + notes, chronological, searchable)
- [x] CLAUDE.md files updated to reflect current architecture

---

## Implementation Phases

### Phase 1: Kill Dead Code + Update Docs
*Fastest win, no risk, unblocks clear thinking.*

**Delete:**
```
computer/vault/.modules/brain/   ← entire directory
```

**Update CLAUDE.md files** — remove all references to:
- TerminusDB, WOQLClient, YAML entity schemas
- Brain module, BrainInterface, brain_create_entity etc.
- BrainEntity Flutter model, entity CRUD widgets

Specifically:
- `computer/CLAUDE.md` — remove brain module section, update module table
- `app/CLAUDE.md` — remove BrainEntity, entity CRUD, schema browser docs; reflect current state
- `computer/vault/.modules/brain/` docs gone with the directory

---

### Phase 2: Backend Rename — `graph` → `brain`
*Mechanical rename. One PR. All Python.*

#### Files to rename

| From | To |
|------|----|
| `computer/parachute/db/graph.py` | `computer/parachute/db/brain.py` |
| `computer/parachute/db/graph_sessions.py` | `computer/parachute/db/brain_sessions.py` |
| `computer/parachute/api/graph.py` | `computer/parachute/api/brain.py` |

#### Class + symbol renames

| File | From | To |
|------|------|-----|
| `db/brain.py` (was graph.py) | `class GraphService` | `class BrainService` |
| `db/brain_sessions.py` | `class GraphSessionStore` | `class BrainSessionStore` |
| `db/brain_sessions.py` | `from parachute.db.graph import GraphService` | `from parachute.db.brain import BrainService` |
| `api/brain.py` | `router = APIRouter(prefix="/graph")` | `router = APIRouter(prefix="/brain")` |
| `config.py` | `def graph_db_path(self)` | `def brain_db_path(self)` |

> **Note:** Do NOT rename the filesystem path. `~/.parachute/graph/parachute.kz` stays as-is.
> Only the Python property name changes.

#### Files to update (imports + usage)

**`computer/parachute/server.py`**
```python
# Before
from parachute.db.graph import GraphService
from parachute.db.graph_sessions import GraphSessionStore
graph = GraphService(db_path=settings.graph_db_path)
session_store = GraphSessionStore(graph)
app.state.graph = graph
get_registry().publish("GraphDB", graph)

# After
from parachute.db.brain import BrainService
from parachute.db.brain_sessions import BrainSessionStore
brain = BrainService(db_path=settings.brain_db_path)
session_store = BrainSessionStore(brain)
app.state.brain = brain
get_registry().publish("BrainDB", brain)
```

**`computer/parachute/mcp_server.py`**
```python
# Before
from parachute.db.graph import GraphService
graph = GraphService(db_path=str(_PARACHUTE_DIR / "graph" / "parachute.kz"))
_db = GraphSessionStore(graph)

# After
from parachute.db.brain import BrainService
brain = BrainService(db_path=str(_PARACHUTE_DIR / "graph" / "parachute.kz"))
_db = BrainSessionStore(brain)
```

**`computer/parachute/api/router.py`** (or wherever api/graph.py is registered)
- Update import and `app.include_router()` call

**`computer/tests/`**
- `conftest.py` — update GraphService → BrainService fixtures
- `unit/test_daily_module.py` — update imports
- `unit/test_mcp_multi_agent.py` — update imports

**Any module that uses `get_registry().get("GraphDB")`**
- Search for `"GraphDB"` and replace with `"BrainDB"`

---

### Phase 3: Frontend Rename — Flutter
*Depends on Phase 2 (API routes changed). One PR.*

#### Files to rename

| From | To |
|------|-----|
| `app/lib/features/brain/services/graph_service.dart` | `brain_service.dart` |
| `app/lib/features/brain/providers/graph_providers.dart` | `brain_providers.dart` |

#### Symbol renames

**`brain_service.dart`**
```dart
// Before
class GraphService {
Future<...> getSchema() async  // calls /api/graph/schema
  Future<...> getSessions(...)   // calls /api/graph/sessions
  Future<...> getProjects(...)   // calls /api/graph/projects
  Future<...> getDailyEntries(...) // calls /api/graph/daily/entries
}

// After
class BrainService {
  Future<...> getSchema() async  // calls /api/brain/schema
  Future<...> getSessions(...)   // calls /api/brain/sessions
  Future<...> getProjects(...)   // calls /api/brain/projects
  Future<...> getDailyEntries(...) // calls /api/brain/daily/entries
}
```

**`brain_providers.dart`**
```dart
// Before
final graphServiceProvider = Provider<GraphService>(...)
final graphSchemaProvider = FutureProvider<...>(...)
final graphSelectedTableProvider = StateProvider<String?>(...)
final graphTableDataProvider = FutureProvider.autoDispose.family<...>(...)

// After
final brainServiceProvider = Provider<BrainService>(...)
final brainSchemaProvider = FutureProvider<...>(...)
final brainSelectedTableProvider = StateProvider<String?>(...)
final brainTableDataProvider = FutureProvider.autoDispose.family<...>(...)
```

**`brain_home_screen.dart`** — update all provider references.

---

### Phase 4: MCP Tools — Rename + Add Cypher Passthrough
*Depends on Phase 2. Adds real agent power.*

#### In `computer/parachute/mcp_server.py`

**Rename existing tools:**

| Current name | New name |
|-------------|----------|
| `get_graph_schema` | `brain_schema` |
| `list_conversations` | `brain_list_sessions` |
| `get_conversation` | `brain_get_session` |
| `list_projects` | `brain_list_projects` |
| `list_entries` | `brain_list_entries` |

**Add two new tools:**

```python
Tool(
    name="brain_query",
    description=(
        "Execute a read-only Cypher query against the Parachute brain (Kuzu graph). "
        "Use for MATCH/RETURN queries. Call brain_schema first to discover tables."
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Cypher query (MATCH/RETURN only)"},
            "params": {"type": "object", "description": "Optional $param bindings"}
        },
        "required": ["query"]
    }
),
Tool(
    name="brain_execute",
    description=(
        "Execute a write Cypher query against the Parachute brain (Kuzu graph). "
        "Use for MERGE, CREATE, SET, DELETE. Use brain_query for reads."
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Cypher mutation query"},
            "params": {"type": "object", "description": "Optional $param bindings"}
        },
        "required": ["query"]
    }
),
```

**Handlers:**
```python
"brain_query": async (args) => {
    results = await brain.execute_cypher(args["query"], args.get("params", {}))
    return json.dumps(results, default=str)
},
"brain_execute": async (args) => {
    # Acquire write lock
    async with brain.write_lock:
        results = await brain.execute_cypher(args["query"], args.get("params", {}))
    return json.dumps({"ok": True, "rows_affected": len(results)}, default=str)
},
```

> **Note:** `brain_execute` uses `write_lock` to serialize mutations, same pattern as existing
> write operations in `BrainSessionStore`.

---

### Phase 5: Brain Tab — Memory Feed UI
*Depends on Phase 3 (BrainService available). New Flutter feature.*

Replace the schema/table browser with a chronological memory feed.

#### New API endpoint needed

`GET /api/brain/memory?limit=50&offset=0&search=&type=all`

Returns a merged, time-sorted list of sessions and notes:
```json
{
  "items": [
    {"kind": "session", "id": "...", "title": "Brain audit", "ts": "2026-03-05T14:00:00Z", "module": "chat"},
    {"kind": "note",    "id": "...", "title": "Morning note", "ts": "2026-03-05T09:14:00Z", "date": "2026-03-05"},
    ...
  ],
  "total": 142
}
```

Backend: add `GET /api/brain/memory` to `api/brain.py`. Query runs two Cypher fetches
(Chat + Note), merges, sorts by timestamp descending, paginates.

#### Flutter UI (`brain_home_screen.dart`)

Structure:
```
BrainHomeScreen
├── SearchBar (calls /api/brain/memory?search=...)
├── FilterChips (All / Conversations / Notes)
└── MemoryFeed (ListView.builder)
    └── MemoryItem (session or note card)
        ├── Icon (💬 or 📓)
        ├── Title
        ├── Subtitle (module + relative time)
        └── onTap → navigate to Chat or Daily
```

State: `brainMemoryProvider` — `FutureProvider.autoDispose.family` keyed on `(filter, search, offset)`.

Date grouping: Items grouped by "Today / Yesterday / This Week / Earlier". Grouping is a
presentation concern — compute in widget from `ts` field, no API changes needed.

Navigation on tap:
- `kind == "session"` → `context.go('/chat/${item.id}')`
- `kind == "note"` → `context.go('/daily?date=${item.date}')`

---

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| `/api/graph/` → `/api/brain/` breaks any hardcoded URLs outside codebase | Search codebase for `/api/graph` before merging Phase 2. Low risk — server is local-only. |
| `"GraphDB"` registry key used by modules | Grep all module code for `get_registry().get("GraphDB")` and update in Phase 2. |
| MCP tool renames break existing agent prompts | Low risk — agents read tool descriptions dynamically. |
| Flutter hot reload cache holds old provider names | Normal `flutter clean` before testing. |
| `brain_execute` allows arbitrary writes | Acceptable — MCP is trusted context (same trust level as chat agent). |

---

## References

- Brainstorm: `docs/brainstorms/2026-03-05-brain-system-redesign-brainstorm.md`
- Related: #199 (original MCP Cypher brainstorm, incorporated here)
- Prior dissolution: `docs/plans/2026-03-04-refactor-graph-as-core-infrastructure-plan.md`
