---
title: Simplify workspace settings UI
type: feat
date: 2026-03-15
issue: 275
---

# Simplify Workspace Settings UI

Strip two overlapping, confusing settings sheets down to what users actually need.

## Problem

Two settings surfaces with 10+ controls between them, when users need 3 actions. The most important one (naming a workspace) is only reachable via an undiscoverable long-press gesture.

| Surface | Entry point | What it has | What's needed |
|---------|-------------|-------------|---------------|
| ContainerSettingsSheet | Gear icon (only when workspace selected) | Name, core memory, delete | Name/rename, delete |
| SessionConfigSheet | Long-press (hidden), tap pending session | Trust level, workspace picker, response mode, mention pattern, promotion banner, sandbox info | Bot activation only |

## Solution

### Phase 1: Simplify ContainerSettingsSheet

**File:** `app/lib/features/chat/widgets/workspace_context_bar.dart`

Strip to essentials:
- [x] **Remove core memory field** — keep in data model, remove from UI
- [x] **Keep:** Name/rename field, delete button with name-to-confirm, save button
- [x] Result: the gear icon opens a clean 2-field sheet (name + delete)

### Phase 2: Remove long-press → SessionConfigSheet for regular sessions

**Files:** `app/lib/features/chat/widgets/session_list_item.dart`, `session_config_sheet.dart`

- [x] **Remove `onLongPress` → `SessionConfigSheet.show()`** from `SessionListItem` (line 78)
- [x] Long-press on sessions now does nothing (or could be repurposed for archive later — out of scope)
- [x] Keep the pending initialization flow intact — tapping a pending session still opens SessionConfigSheet for bot activation

### Phase 3: Slim down SessionConfigSheet to bot activation only

**File:** `app/lib/features/chat/widgets/session_config_sheet.dart`

Remove sections that aren't needed for the bot activation flow:
- [x] **Remove trust level selector** — sandboxed is the default; direct is developer-only
- [x] **Remove workspace picker dropdown** — can't reassign workspaces mid-chat
- [x] **Remove promotion banner** ("name this workspace") — moves to Phase 4
- [x] **Remove sandbox info** — read-only display of hardcoded values, not useful
- [x] **Keep:** Platform info header, response mode, mention pattern, activate/deny buttons
- [x] **Rename:** "Session Settings" → "Bot Settings" (since that's all it is now)
- [x] Result: SessionConfigSheet is exclusively for bot session activation/configuration

### Phase 4: Make workspace promotion discoverable

**File:** `app/lib/features/chat/widgets/workspace_context_bar.dart`

When the active workspace is unnamed (not `isWorkspace`), show a visual nudge:
- [x] **Add inline "Name this workspace" banner** in the `WorkspaceContextBar` — shown when `activeSlug != null` and the container `isWorkspace == false`
- [x] Banner includes a text field + "Name" button (same pattern as the old promotion banner in SessionConfigSheet)
- [x] After naming, banner disappears and the workspace name appears normally
- [x] This replaces the gear icon for unnamed workspaces — gear shows only for named workspaces

### Phase 5: Clean up server-side

**File:** `computer/parachute/api/sessions.py`

- [x] **PATCH /api/chat/{id}/config** — remove `containerId` handling (workspace can't be changed mid-session). Trust level stays as an API field for programmatic use, just not in the UI.
- [x] No model changes needed — `SessionConfigUpdate` fields are all optional, removing UI doesn't require removing API fields

## Files Changed

| File | Changes |
|------|---------|
| `workspace_context_bar.dart` | Remove core memory from ContainerSettingsSheet; add promotion banner to WorkspaceContextBar |
| `session_config_sheet.dart` | Remove trust level, workspace picker, promotion banner, sandbox info; rename to "Bot Settings" |
| `session_list_item.dart` | Remove `onLongPress` → SessionConfigSheet |
| `container_providers.dart` | May no longer need `allContainersProvider` if promotion banner moves to context bar |

## Acceptance Criteria

- [x] Gear icon opens simplified sheet: name + delete only
- [x] No long-press gesture opens settings on regular sessions
- [x] Tapping a pending bot session still opens bot config (response mode, mention pattern)
- [x] Unnamed workspace shows inline "Name this workspace" banner in context bar
- [x] Naming a workspace from the banner promotes it and updates the picker
- [x] `flutter analyze` passes with 0 errors

## What We're NOT Doing

- Moving chats between workspaces
- Advanced/developer settings surface
- Repurposing long-press for other actions (could be future work)
- Removing core memory from the data model or API
- Removing trust level from the API (just from the UI)
