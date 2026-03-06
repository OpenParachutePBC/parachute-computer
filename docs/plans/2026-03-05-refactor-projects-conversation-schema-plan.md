---
title: Projects + Conversation Schema Unification
type: refactor
date: 2026-03-05
issue: 196
---

# Projects + Conversation Schema Unification

Rename and unify the graph schema to match the mental model: `Project → Conversation → Exchange` for the interactive layer, `Note / Card / Caller` for the capturing and automation layers. Drops redundant tables (`Chat_Session`, `Day`), renames the rest, and wires `core_memory` from Project into the system prompt.

## Acceptance Criteria

- [ ] `Project` table replaces `Parachute_ContainerEnv` — same data, adds `core_memory` (STRING, max 4000 chars)
- [ ] `Conversation` table replaces `Parachute_Session` — same fields, `container_env_id` renamed to `project_id`
- [ ] `Chat_Session` table dropped — `HAS_EXCHANGE` rel now links `Conversation → Exchange`
- [ ] `Exchange` table replaces `Chat_Exchange` — no field changes
- [ ] `Note` table replaces `Journal_Entry` — adds `note_type` (default `"journal"`), `aliases`, `status`, `created_by`
- [ ] `Day` table and `HAS_ENTRY`, `HAS_CARD` rels dropped — queries filter by `date` field directly
- [ ] Migration script runs on first server start after update, converting all existing data
- [ ] `core_memory` from the session's Project injects as `## Project Context` in `_build_system_prompt()`
- [ ] `/api/containers` → `/api/projects`, `/api/containers/{slug}/files` → `/api/projects/{slug}/files`
- [ ] Flutter: `ContainerEnv` → `Project`, `containerEnvId` → `projectId`, "Container Files" → "Project Files"
- [ ] Brain tab graph providers updated to use new table names
- [ ] Chat session list filters to human-initiated conversations by default (`source = "parachute"`, non-bridge agents)
- [ ] All tests pass

## Architecture

### Resulting schema

```
Project (slug PK, display_name, core_memory, created_at)
  project_id field on Conversation (nullable, no rel table needed)

Conversation (session_id PK, project_id, mode, trust_level, source, ...)  ← was Parachute_Session + Chat_Session
  └─[HAS_EXCHANGE]→ Exchange (exchange_id PK, session_id, ...)              ← was Chat_Exchange

Note (entry_id PK, note_type, content, audio_path, aliases, status, created_by, date, ...)  ← was Journal_Entry
Card (card_id PK, agent_name, date, content, status, ...)
Caller (name PK, ...)
Parachute_PairingRequest (request_id PK, ...)
```

### Key decisions

- **`project_id` field, not `HAS_CONVERSATION` rel** — `container_env_id` was already a field; keeping this pattern is simpler and sufficient for all filtering queries. `HAS_CONVERSATION` as a graph rel can be added later if Kuzu traversal queries become needed.
- **`core_memory` soft limit: 4,000 chars** — prevents the field becoming a dump; mirrors Letta's memory block sizing.
- **Chat_Session dropped entirely** — `Conversation` (renamed `Parachute_Session`) is the single authoritative session table. `bridge_agent.py` writes `Exchange` nodes linked to `Conversation` directly.
- **Migration via Python copy** — Kuzu has no `ALTER TABLE RENAME`. Migration reads all rows from old tables into Python, creates new tables, inserts rows, drops old tables. Runs once on server start, gated by presence of old table names.

## Implementation

### Phase 1 — Graph schema + migration (Python backend, no API breaks yet)

**`computer/parachute/db/graph_sessions.py`**

Rename every Cypher query string and method:

| Old | New |
|-----|-----|
| `Parachute_Session` | `Conversation` |
| `Parachute_ContainerEnv` | `Project` |
| `container_env_id` | `project_id` |
| `ContainerEnv` (Python model) | `Project` |
| `create_container_env()` | `create_project()` |
| `get_container_env()` | `get_project()` |
| `list_container_envs()` | `list_projects()` |
| `delete_container_env()` | `delete_project()` |
| `delete_container_env_if_unreferenced()` | `delete_project_if_unreferenced()` |
| `list_orphan_container_env_slugs()` | `list_orphan_project_slugs()` |
| `_node_to_container_env()` | `_node_to_project()` |

Schema changes in `ensure_node_table` calls:
- `Project`: add `"core_memory": "STRING"` field
- `Conversation`: rename `container_env_id` → `project_id`; add `project_id` to CREATE INSERT and `_row_to_session()`
- `update_session()`: rename `container_env_id` update path → `project_id`

**`computer/parachute/db/migration.py`** (add `migrate_schema_v2()`)

```python
async def migrate_schema_v2(graph: GraphService):
    """
    Rename tables to match new ontology:
      Parachute_Session → Conversation (container_env_id → project_id)
      Parachute_ContainerEnv → Project (+ core_memory field)
      Chat_Session → drop
      Chat_Exchange → Exchange
    Runs once, gated by old table presence.
    """
    existing = await graph.list_table_names()
    if "Parachute_Session" not in existing:
        return  # already migrated

    # 1. Migrate Parachute_ContainerEnv → Project
    rows = await graph.execute_cypher("MATCH (e:Parachute_ContainerEnv) RETURN e")
    await graph.ensure_node_table("Project", {"slug": "STRING", "display_name": "STRING",
                                               "core_memory": "STRING", "created_at": "STRING"},
                                   primary_key="slug")
    for row in rows:
        await graph.execute_cypher(
            "MERGE (:Project {slug: $slug, display_name: $display_name, "
            "core_memory: $core_memory, created_at: $created_at})",
            {**row, "core_memory": ""}
        )
    await graph.execute_cypher("MATCH (e:Parachute_ContainerEnv) DETACH DELETE e")
    # (drop table via graph.drop_table if available, else leave empty)

    # 2. Migrate Parachute_Session → Conversation
    # ... same pattern, rename container_env_id → project_id on each row

    # 3. Migrate Chat_Exchange → Exchange
    # ... same pattern, no field changes

    # 4. Drop Chat_Session + HAS_EXCHANGE (old), create new HAS_EXCHANGE (Conversation→Exchange)
    # ... recreate rel from exchange.session_id → Conversation match

    logger.info("Schema migration v2 complete")
```

Call `migrate_schema_v2()` in server startup (`main.py` or `graph.py` `open()`) before modules load.

**`computer/parachute/models/session.py`**

- `ContainerEnv` → `Project` (add `core_memory: Optional[str] = None`)
- `ContainerEnvCreate` → `ProjectCreate`
- `Session.container_env_id` → `Session.project_id`
- `SessionCreate.container_env_id` → `SessionCreate.project_id`
- `SessionUpdate.container_env_id` → `SessionUpdate.project_id`

---

### Phase 2 — Module updates

**`computer/modules/chat/module.py`**

- Remove `ensure_node_table("Chat_Session", ...)` entirely — `Conversation` (from core) is the single session table
- `ensure_node_table("Chat_Exchange", ...)` → `ensure_node_table("Exchange", ...)`
- `ensure_rel_table("HAS_EXCHANGE", "Chat_Session", "Chat_Exchange")` → `ensure_rel_table("HAS_EXCHANGE", "Conversation", "Exchange")`
- Log message update

**`computer/modules/daily/module.py`**

- `ensure_node_table("Journal_Entry", ...)` → `ensure_node_table("Note", ...)` with additional fields:
  - Add `"note_type": "STRING"` (default `"journal"` in all INSERT/MERGE)
  - Add `"aliases": "STRING"` (JSON array, default `"[]"`)
  - Add `"status": "STRING"` (default `"active"`)
  - Add `"created_by": "STRING"` (default `"user"`)
- Remove `ensure_node_table("Day", ...)` and `ensure_rel_table("HAS_ENTRY", "Day", "Journal_Entry")`
- Remove `ensure_rel_table("HAS_CARD", "Day", "Card")`
- `write_journal_entry()`:
  - Remove Day node upsert (step 1) and HAS_ENTRY MERGE (step 3)
  - `MERGE (e:Journal_Entry ...)` → `MERGE (e:Note ...)` with `note_type: "journal"`, `created_by: "user"`, `aliases: "[]"`, `status: "active"`
- All other `MATCH (e:Journal_Entry ...)` → `MATCH (e:Note ...)`
- `_delete_all()`: remove Day DELETE, update Journal_Entry DELETE → Note DELETE
- `_node_to_journal_entry()` → `_node_to_note()`
- Migration guard: `ensure_node_table` is idempotent; daily module migration (redo log replay) update Node table name

Add `migrate_daily_v2()` to `module.py` `on_load()`: if `Journal_Entry` table still exists (pre-schema-v2 start without migration having run), replay via redo log into `Note`. In practice the main `migrate_schema_v2` above runs first.

---

### Phase 3 — Core, API, and peripherals

**`computer/parachute/core/bridge_agent.py`**

- `Chat_Session` → `Conversation` in all Cypher (MERGE node, MATCH for HAS_EXCHANGE)
- `Chat_Exchange` → `Exchange`
- Comments updated accordingly

**`computer/parachute/core/daily_agent_tools.py`** and **`daily_agent.py`**

- `Journal_Entry` → `Note` in all Cypher queries

**`computer/parachute/core/orchestrator.py`**

- `container_env_id` → `project_id` everywhere
- In `run_streaming()`, after resolving session: load `core_memory` from Project node if `session.project_id` is set
  ```python
  project_memory: Optional[str] = None
  if session.project_id:
      project = await self.session_store.get_project(session.project_id)
      if project and project.core_memory:
          project_memory = project.core_memory[:4000]  # soft limit
  ```
- Pass `project_memory` to `_build_system_prompt()`
- In `_build_system_prompt()`: add `project_memory: Optional[str] = None` param; if set, append after mode framing:
  ```
  ## Project Context
  {project_memory}
  ```
- Orphan pruning: `container_env_id` → `project_id`, `list_container_envs()` → `list_projects()`
- `PARACHUTE_CONTAINER_ENV_ID` env var: rename to `PARACHUTE_PROJECT_ID` (keep backward-compat alias read)

**`computer/parachute/core/sandbox.py`** and **`session_manager.py`**

- `container_env_id` → `project_id` throughout

**`computer/parachute/api/containers.py`** → **`computer/parachute/api/projects.py`**

- Rename file
- Router prefix: `/api/projects` (was `/api/containers`)
- All `ContainerEnv`/`container_env` references → `Project`/`project`
- Response envelope: `{"project": ...}` and `{"projects": [...]}`
- Update import in `main.py`: `from parachute.api.projects import router as projects_router`

**`computer/parachute/api/container_files.py`**

- Route prefix: `/api/projects/{slug}/files` (was `/api/containers/{slug}/files`)
- Internal logic unchanged (still operates on the same Docker container slug)

**`computer/parachute/api/graph.py`**

- Route: `/api/graph/projects` (was `/api/graph/container_envs`)
- All Cypher strings: `Parachute_Session` → `Conversation`, `Parachute_ContainerEnv` → `Project`, `Chat_Session` → `Conversation`, `Chat_Exchange` → `Exchange`, `Journal_Entry` → `Note`
- `/api/graph/sessions` default filter: add `WHERE s.source = 'parachute' AND (s.agent_type IS NULL OR s.agent_type = 'orchestrator')` as default (overrideable via `?all=true` query param)
- Update docstring table comments

**`computer/parachute/mcp_server.py`**

- `container_env_id` → `project_id`
- `/container_envs` graph call → `/projects`

---

### Phase 4 — Flutter

**`app/lib/features/chat/models/container_env.dart`** → **`project.dart`**

```dart
class Project {
  final String slug;
  final String displayName;
  final String? coreMemory;
  final DateTime createdAt;
  // fromJson, toJson, copyWith
}

class ProjectCreate {
  final String displayName;
  final String? slug;
  final String? coreMemory;
}
```

**`app/lib/features/chat/services/container_env_service.dart`** → **`project_service.dart`**

- Class: `ProjectService`
- `listContainerEnvs()` → `listProjects()` → `GET /api/projects`
- `createContainerEnv()` → `createProject()` → `POST /api/projects`
- `deleteContainerEnv()` → `deleteProject()` → `DELETE /api/projects/{slug}`
- Response envelope: `project` (singular) from create

**`app/lib/features/chat/providers/container_env_providers.dart`** → **`project_providers.dart`**

- `containerEnvServiceProvider` → `projectServiceProvider`
- `containerEnvsProvider` → `projectsProvider`

**`app/lib/features/chat/models/chat_session.dart`**

- `containerEnvId` → `projectId` (field, fromJson key `"projectId"`, toJson key `"projectId"`)

**`app/lib/features/chat/providers/chat_message_providers.dart`**

- `containerEnvId` → `projectId` throughout

**`app/lib/features/chat/widgets/new_chat_sheet.dart`**

- `ContainerEnv` → `Project`, `containerEnvsProvider` → `projectsProvider`
- Label: "Container" → "Project"

**`app/lib/features/chat/widgets/session_config_sheet.dart`** and **`session_list_panel.dart`**

- Same rename pattern

**`app/lib/features/chat/screens/agent_hub_screen.dart`** and **`chat_shell.dart`**

- Provider/model renames

**`app/lib/features/chat/screens/chat_screen.dart`**

- "Container Files" label → "Project Files" (folder-zip icon tooltip/title)

**`app/lib/features/chat/services/container_files_service.dart`**

- Endpoint: `/api/projects/{slug}/files` (was `/api/containers/{slug}/files`)

**`app/lib/features/chat/providers/container_files_providers.dart`**

- No logic changes; follows service update

**`app/lib/features/brain/services/graph_service.dart`**

- `getContainerEnvs()` → `getProjects()` — endpoint `/api/graph/projects`
- `getDailyEntries()` → `getNotes()` — endpoint `/api/graph/daily/entries` (endpoint path unchanged, table name in response changes)

**`app/lib/features/brain/providers/graph_providers.dart`**

```dart
case 'Conversation':     // was 'Parachute_Session'
  return service.getSessions(limit: 50);
case 'Project':          // was 'Parachute_ContainerEnv'
  return service.getProjects(limit: 50);
case 'Note':             // was 'Journal_Entry'
  return service.getNotes(limit: 50);
```

**`app/lib/features/brain/screens/brain_home_screen.dart`**

- Update any hardcoded table name display strings

---

### Phase 5 — Tests

**`computer/tests/unit/test_container_files.py`**

- Endpoint paths: `/api/containers/` → `/api/projects/`
- Model references: `ContainerEnv` → `Project`

**`computer/tests/unit/test_orchestrator_phases.py`**

- `container_env_id` → `project_id` in session fixtures

**`computer/tests/unit/test_daily_module.py`**

- `Journal_Entry` → `Note` in all table assertions
- Remove Day-related assertions

---

## References

- Brainstorm: `docs/brainstorms/2026-03-05-projects-conversation-schema-brainstorm.md`
- Depends on: #197 (system prompt modes — `_build_system_prompt()` architecture, merged ✅)
- Related: #193 (mode field — wired and merged via #197)
