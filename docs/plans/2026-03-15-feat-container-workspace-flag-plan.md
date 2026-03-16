---
title: "Add is_workspace flag to Container model"
type: feat
date: 2026-03-15
issue: 272
---

# Add `is_workspace` Flag to Container Model

## Overview

Add a boolean `is_workspace` flag to the Container model to distinguish user-promoted workspaces from auto-created sandbox containers. This fixes workspace picker pollution, broken promotion detection, and enables workspace-aware lifecycle behavior.

## Problem

The system auto-creates containers for every sandboxed session (slug: 12-char hex, display_name: `"Session {sid[:8]}"`). There's no way to distinguish these from intentionally named workspaces:

1. **Picker pollution** — `containersProvider` returns ALL containers, flooding the workspace picker with `"Session XXXXXXXX"` entries
2. **Broken promotion detection** — `session_config_sheet.dart` uses a UUID v4 regex (`8-4-4-4-12` with hyphens) but auto-slugs are 12-char hex strings with no hyphens — regex never matches
3. **Flat delete UX** — named workspaces with many sessions get the same lightweight delete confirmation as throwaway sandboxes

## Proposed Solution

### Phase 1 — Server: Add `is_workspace` to Container model

**`computer/parachute/models/session.py`:**
- Add `is_workspace: bool = False` to `Container` model with alias `isWorkspace`
- Add `is_workspace: bool | None = None` to `ContainerUpdate` model

**`computer/parachute/db/brain_chat_store.py`:**
- Add `"is_workspace": "BOOL"` to `ensure_schema` Container table definition
- Update `create_container()` to accept and persist `is_workspace` param (default `False`)
- Update `_node_to_container()` to read `is_workspace` from graph row (default `False` for existing records missing the column)
- Update `update_container()` to accept and persist `is_workspace` param

**`computer/parachute/api/containers.py`:**
- `POST /api/containers` — set `is_workspace=True` (explicit creation = workspace)
- `PATCH /api/containers/{slug}` — if `display_name` is being set on a container where `is_workspace == False`, auto-promote to `is_workspace=True`. This is the promotion path.
- `GET /api/containers` — add optional `?workspace=true|false` query param for filtering. Default: return all (backwards compatible). The Flutter picker will pass `?workspace=true`.

**`computer/parachute/core/orchestrator.py`:**
- Auto-sandbox creation (line ~1506) — no change needed, `is_workspace` defaults to `False`

**Orphan reconciliation (`brain_chat_store.py`):**
- Update `list_orphan_container_slugs` to only consider containers where `is_workspace == false`. Named workspaces are durable — never auto-pruned.

**Files touched:**
| File | Change |
|------|--------|
| `models/session.py` | Add `is_workspace` to `Container`, `ContainerUpdate` |
| `db/brain_chat_store.py` | Schema column, create, read, update, orphan filter |
| `api/containers.py` | Auto-promote on PATCH, filter param on GET |

### Phase 2 — Flutter: Use the flag

**`app/lib/features/chat/models/container_env.dart`:**
- Add `final bool isWorkspace;` field (default `false`)
- Parse `json['isWorkspace'] as bool? ?? false` in `fromJson`
- Include in `toJson` and `copyWith`

**`app/lib/features/chat/services/container_service.dart`:**
- Update `listContainers()` to pass `?workspace=true` query param (workspace picker only shows workspaces)
- Add `listAllContainers()` method without filter (for session config sheet dropdown, which needs all containers)

**`app/lib/features/chat/providers/container_providers.dart`:**
- `containersProvider` calls `listContainers()` (workspaces only) — used by workspace picker
- Add `allContainersProvider` calling `listAllContainers()` — used by session config sheet

**`app/lib/features/chat/widgets/workspace_context_bar.dart`:**
- No change needed — already reads from `containersProvider`, which will now return workspaces only

**`app/lib/features/chat/widgets/session_config_sheet.dart`:**
- Remove `_uuidPattern` regex and `_hasUnnamedContainer` getter
- Replace with `_isUnnamedContainer` that checks `isWorkspace == false` from the container data
- The promotion banner shows when the session's container has `isWorkspace == false`
- Dropdown uses `allContainersProvider` to show all containers (workspaces + sandboxes)
- After successful `_nameWorkspace()`, invalidate both providers

### Phase 3 — Delete UX for workspaces

**`app/lib/features/chat/widgets/workspace_context_bar.dart` (ContainerSettingsSheet):**
- Before delete, fetch session count for the workspace
- Show in confirmation dialog: "Delete 'Parachute Dev'? This workspace has **8 conversations** that will be ungrouped. The sandbox environment and all files will be permanently deleted."
- Two-step confirmation for workspaces: type the workspace name to confirm (like GitHub repo deletion)

## Acceptance Criteria

- [x] Container model has `is_workspace` boolean field (Python + Dart)
- [x] `POST /api/containers` creates with `is_workspace=True`
- [x] Auto-sandbox containers have `is_workspace=False`
- [x] `PATCH /api/containers/{slug}` with `displayName` auto-promotes to `is_workspace=True`
- [x] `GET /api/containers?workspace=true` filters to workspaces only
- [x] Workspace picker only shows `is_workspace=True` containers
- [x] Session config sheet shows all containers in dropdown
- [x] Promotion banner uses `isWorkspace` flag instead of UUID regex
- [x] Orphan reconciliation skips `is_workspace=True` containers
- [x] Workspace delete shows session count and requires name confirmation
- [x] Existing containers without the field default to `is_workspace=False`
- [x] `flutter analyze` passes with 0 errors
- [x] Python tests pass

## Technical Considerations

**Schema migration requires explicit ALTER TABLE.** `ensure_node_table` uses `CREATE NODE TABLE IF NOT EXISTS` which does NOT add columns to existing tables. We need a `_ensure_container_columns()` step (same pattern as `modules/daily/module.py:481`) that checks `get_table_columns("Container")` and runs `ALTER TABLE Container ADD is_workspace BOOLEAN DEFAULT false` if missing. Existing Container nodes will then have `is_workspace = false` automatically.

**`BOOLEAN` type is proven.** The `Chat` node already uses `"archived": "BOOLEAN"` — no type concerns.

**Backwards compatibility:** The `isWorkspace` field defaults to `false` in both Python and Dart models, so existing API consumers are unaffected.

**Auto-promotion semantics:** Setting `displayName` on a non-workspace container auto-sets `is_workspace=True`. This means the PATCH endpoint serves double duty (rename + promote). An explicit `is_workspace` field in `ContainerUpdate` allows manual control if needed later, but the auto-promote covers the primary use case.

**Two providers vs one:** Having `containersProvider` (workspaces) and `allContainersProvider` (everything) is cleaner than filtering client-side, because the workspace picker is the hot path and shouldn't pay for fetching containers it'll never show.

## Dependencies & Risks

- **Depends on PR #267** (workspace context bar) — already merged
- **Low risk** — additive schema change, existing behavior unchanged for containers without the flag
