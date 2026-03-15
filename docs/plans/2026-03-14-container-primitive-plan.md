---
title: "Container as Core Primitive"
type: feat
date: 2026-03-14
issue: 264
---

# Container as Core Primitive

Rename `Project` → `Container` across the full stack and close three integration gaps: container promotion (naming an unnamed container), container selection (already implemented — just needs the rename), and caller → container routing.

## Problem Statement

Every sandboxed chat creates a Docker container, but only explicitly-created "Projects" are tracked as graph nodes. This creates an artificial gap — containers exist in Docker but aren't visible in the graph until a user deliberately creates a Project. The "Project" name also implies something heavier than what this actually is: a Docker execution environment.

## Acceptance Criteria

- [x] `Project` renamed to `Container` in Python models, API routes, graph DB table, and Flutter
- [x] API routes change from `/api/projects` to `/api/containers`
- [x] `project_id` renamed to `container_id` in Session model and all references
- [x] `PATCH /api/containers/{slug}` endpoint exists for renaming/updating containers
- [x] Flutter sidebar, new chat sheet, and session config sheet use "Container" terminology
- [ ] Flutter has UI to rename a container (promotion act) from sidebar context menu
- [ ] Caller config supports `container_slug` field to target a named container
- [x] `PARACHUTE_PROJECT_ID` env var renamed to `PARACHUTE_CONTAINER_ID`

## Proposed Solution

### Phase 1: Python Model + DB Rename

**Files:** `models/session.py`, `db/brain_chat_store.py`

1. Rename `Project` → `Container`, `ProjectCreate` → `ContainerCreate`
2. Rename `project_id` → `container_id` in `Session`, `SessionCreate`, `SessionUpdate` (with alias `containerId`)
3. Update graph table from `Project` to `Container` in `ensure_node_table()` and all Cypher queries
4. Rename all DB methods: `create_project()` → `create_container()`, `get_project()` → `get_container()`, etc.

### Phase 2: API Rename

**Files:** `api/projects.py` → `api/containers.py`, `api/__init__.py`, `api/container_files.py`, `api/brain.py`, `api/credentials.py`

1. Rename `projects.py` → `containers.py`, update router prefix to `/containers`
2. Update response envelopes: `{"projects": ...}` → `{"containers": ...}`
3. Update `container_files.py` router prefix from `/projects` to `/containers`
4. Update brain API: `GET /api/brain/projects` → `GET /api/brain/containers`
5. Add `PATCH /api/containers/{slug}` endpoint for updating `display_name` and `core_memory`

### Phase 3: Core Logic Rename

**Files:** `core/orchestrator.py`, `core/session_manager.py`, `core/sandbox.py`, `core/daily_agent.py`, `mcp_server.py`

1. Rename all `project_id` → `container_id` variable names and parameters
2. Rename all `get_project()` → `get_container()` calls
3. Rename `PARACHUTE_PROJECT_ID` env var → `PARACHUTE_CONTAINER_ID`
4. Update `_build_system_prompt()`: `## Project Context` → `## Container Context`
5. Add `container_slug` support to caller config in `daily_agent.py` — if set, use that slug instead of auto-generating `caller-{name}`

### Phase 4: Flutter Rename

**Files:** All files in `app/lib/features/chat/` referencing Project

1. Rename `project.dart` → `container_model.dart`, classes `Project` → `Container`, `ProjectCreate` → `ContainerCreate`
2. Rename `project_service.dart` → `container_service.dart`, class `ProjectService` → `ContainerService`
3. Add `updateContainer(slug, {displayName?, coreMemory?})` method to service
4. Rename `project_providers.dart` → `container_providers.dart`, all provider names
5. Update `ChatSession.projectId` → `ChatSession.containerId`
6. Update `NewChatConfig.projectId` → `NewChatConfig.containerId`
7. Update all widgets: `new_chat_sheet.dart`, `session_config_sheet.dart`, `session_list_panel.dart`, `chat_shell.dart`
8. Desktop sidebar: add "Rename" option to container context menu (alongside existing "Delete")

### Phase 5: Tests + Docs

1. Update `test_orchestrator_phases.py` and any other test files referencing `project_id`
2. Update `test_trust_levels.py` if it references project naming
3. Update CLAUDE.md files if they reference Projects

## Technical Considerations

- **No migration needed:** The `Project` graph table is not in heavy use. We can drop and recreate as `Container`. Existing containers will be re-discovered on next session creation.
- **API backward compatibility:** Not needed — Project API isn't consumed by external clients. Flutter app and server deploy together.
- **`container_id` already in use:** The `ChatRequest` model already uses `container_id` as its parameter name, mapping to `project_id` internally. This rename makes the internal model match the external API.
- **Docker naming unchanged:** `parachute-env-{slug}` container naming convention stays the same — it's an internal implementation detail.
- **Caller routing:** Adding optional `container_slug` to caller YAML config. When set, the caller uses that container instead of auto-creating `caller-{name}`. When unset, behavior is unchanged.

## Dependencies & Risks

- **Low risk:** This is primarily a rename. The logic doesn't change, just the names.
- **Graph table rename:** Dropping `Project` table and creating `Container` table means existing project records need to be recreated. Since there are few named projects in practice, this is acceptable. Auto-created containers will be recreated naturally on next chat.
- **Coordination:** Python API and Flutter service must update route paths together (`/projects` → `/containers`).

## References

- Brainstorm: `docs/brainstorms/2026-03-14-container-primitive-brainstorm.md`
- Prior schema unification: Issue #196
- Container architecture: Issues #145, #146, #149
