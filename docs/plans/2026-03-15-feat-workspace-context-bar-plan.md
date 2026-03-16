---
title: "Workspace Context Bar — Unified Container Navigation"
type: feat
date: 2026-03-15
issue: 266
---

# Workspace Context Bar — Unified Container Navigation

## Overview

Replace the three-breakpoint chat layout (mobile / tablet / desktop-with-sidebar) with a two-breakpoint layout (mobile / panel) and a unified **workspace context bar** at the top of the session list. This gives container navigation the same UX on every screen size and removes the desktop-only sidebar.

## Problem

Container switching has three implementations based on screen width:
- **Mobile** (<600px): tiny filter chip in header → bottom sheet
- **Tablet** (600–1199px): same chip → bottom sheet
- **Desktop** (≥1200px): dedicated 220px `_ContainerEnvSidebar`

Primary usage is tablet/mobile, so the richest workspace UI (sidebar) is rarely seen. The filter chip treats containers as a filter rather than "the place you're working in."

## Proposed Solution

### Phase 1 — WorkspaceContextBar widget

Create a self-contained widget that replaces both the filter chip (mobile/tablet) and the sidebar (desktop). It sits at the top of `SessionListPanel`, above the session list.

**New file:** `app/lib/features/chat/widgets/workspace_context_bar.dart`

```
┌──────────────────────────────────┐
│ ▼ All Chats                  ⚙ + │  ← default state
│   12 conversations               │
├──────────────────────────────────┤

│ ▼ Parachute Dev      📁  ⚙  + │  ← workspace selected
│   8 conversations                │
├──────────────────────────────────┤
```

**Widget structure:**
```dart
class WorkspaceContextBar extends ConsumerWidget {
  // Row 1: workspace name (tappable → picker) + action icons
  // Row 2: session count subtitle
}
```

**Behavior:**
- Tapping the workspace name opens a picker:
  - Mobile/tablet (<600px or isScrollControlled modal): **bottom sheet** (reuse existing `showModalBottomSheet` pattern)
  - Desktop/wide (≥600px panel mode): **PopupMenuButton** or small anchored overlay
- Picker shows:
  - "All Chats" with session count
  - Named containers only (from `containersProvider`) with session counts
  - "+ New Workspace" action at bottom
- Action icons (visible when a workspace is selected):
  - **📁 Files** → navigates to `ContainerFileBrowserScreen` for that slug
  - **⚙ Settings** → opens container settings (rename, core memory, delete)
  - **+ New Chat** → creates new chat in this workspace (already exists, just move here)

**Provider changes:**
- Add `containerSessionCountsProvider` — derives per-container session counts from `chatSessionsProvider` so the picker can show "Parachute Dev (8)" without extra API calls.

**Files touched:**
| File | Change |
|------|--------|
| `widgets/workspace_context_bar.dart` | **NEW** — the workspace bar widget |
| `widgets/session_list_panel.dart` | Replace header Row with `WorkspaceContextBar` + archive toggle. Remove `_buildEnvChip` and `_showEnvPicker` methods entirely |
| `providers/container_providers.dart` | Add `containerSessionCountsProvider` |

### Phase 2 — Kill the Desktop Sidebar

Remove the 1200px breakpoint and the three-column desktop layout. Two layout modes remain.

**Changes to `chat_layout_provider.dart`:**
```dart
// BEFORE: 3 modes
enum ChatLayoutMode { mobile, tablet, desktop }
class ChatLayoutBreakpoints {
  static const double tablet = 600;
  static const double desktop = 1200;  // DELETE
}

// AFTER: 2 modes
enum ChatLayoutMode { mobile, panel }
class ChatLayoutBreakpoints {
  static const double panel = 600;
  static ChatLayoutMode fromWidth(double width) {
    return width >= panel ? ChatLayoutMode.panel : ChatLayoutMode.mobile;
  }
}
```

**Changes to `chat_shell.dart`:**
- Delete `_DesktopLayout` widget entirely (~35 lines)
- Delete `_ProjectSidebar` widget entirely (~130 lines)
- Delete `_EnvItem` widget entirely (~60 lines)
- Rename `_TabletLayout` → `_PanelLayout` (this now serves both tablet and desktop)
- Update the `switch` in `ChatShell.build` to handle two modes
- Remove `project.dart` and `project_providers.dart` imports (sidebar was the last consumer)

**Changes to `session_list_panel.dart`:**
- Remove the `layoutMode != ChatLayoutMode.desktop` guard around the env chip (Phase 1 already replaced the chip with the context bar, which shows on all modes)

**Changes to `isPanelModeProvider`:**
```dart
// BEFORE
return mode != ChatLayoutMode.mobile;
// AFTER (same logic, cleaner)
return mode == ChatLayoutMode.panel;
```

**Files touched:**
| File | Change |
|------|--------|
| `providers/chat_layout_provider.dart` | Remove `desktop` enum value and 1200 breakpoint |
| `screens/chat_shell.dart` | Delete `_DesktopLayout`, `_ProjectSidebar`, `_EnvItem`. Rename `_TabletLayout` → `_PanelLayout` |
| `widgets/session_list_panel.dart` | Remove desktop-mode guard (if any remains after Phase 1) |

### Phase 3 — Container Promotion Flow

When a session runs in an unnamed sandbox container, surface a "Name this workspace" action so the user can promote it.

**Changes to `session_config_sheet.dart`:**
- In `_buildContainerPicker`, when the session has a `containerId` that matches a UUID pattern (unnamed container), show a text field + "Name this workspace" button instead of the existing dropdown
- Naming sends `PATCH /api/containers/{slug}` with `displayName`
- On success, invalidate `containersProvider` and the newly named container appears in the workspace picker

**Alternatively** (simpler approach): add a "Name this workspace" row above the Environment dropdown that's only visible when the session's `containerId` is a UUID slug (unnamed). Tapping it shows an inline text field. This keeps the existing dropdown for re-assigning to a different named container.

**Server-side check:** Verify `PATCH /api/containers/{slug}` supports setting `displayName` on an existing unnamed container. (Based on PR #265 review, this endpoint exists and was fixed to return proper errors.)

**Files touched:**
| File | Change |
|------|--------|
| `widgets/session_config_sheet.dart` | Add "Name this workspace" action for unnamed containers |
| `providers/container_providers.dart` | May need a `renameContainer` helper or just call service directly |

### Phase 4 — Quick Access Actions in Context Bar

Wire up the Files and Settings buttons that Phase 1 added as placeholders.

**Files button (📁):**
- Navigates to `ContainerFileBrowserScreen(containerSlug: slug)`
- Uses `Navigator.push` with `rootNavigator: true` so it overlays the full chat layout

**Settings button (⚙):**
- Opens a bottom sheet with container settings:
  - Display name (editable)
  - Core memory (editable textarea)
  - Delete container (with confirmation)
- Reuse existing patterns from `_showCreateEnvDialog` / `_confirmDeleteEnv` in the old sidebar

**Files touched:**
| File | Change |
|------|--------|
| `widgets/workspace_context_bar.dart` | Wire Files → `ContainerFileBrowserScreen`, Settings → new sheet |
| `widgets/container_settings_sheet.dart` | **NEW** — bottom sheet for rename/memory/delete |

## Acceptance Criteria

- [x] Workspace context bar visible at top of session list on all screen sizes
- [x] Tapping workspace name opens picker with named containers + session counts
- [x] Selecting a workspace filters sessions (same behavior as current)
- [x] Desktop no longer shows a sidebar — two-column layout only (≥600px)
- [x] `ChatLayoutMode` enum has two values: `mobile` and `panel`
- [x] Only named containers appear in the workspace picker
- [x] "Name this workspace" action in session config for unnamed containers
- [x] Files button navigates to file browser for active workspace
- [x] Settings button opens container settings sheet
- [x] `flutter analyze` passes with 0 errors
- [x] Existing session filtering behavior unchanged (client-side, from `chatSessionsProvider`)

## Technical Considerations

**Prerequisite:** This plan assumes the Container rename from PR #265 has landed. References use the new naming: `ContainerEnv`, `containersProvider`, `activeContainerProvider`, `containerSessionsProvider`, `ContainerService`.

**Provider naming on local main:** Local main currently has the old `Project` naming because remote main (with the rename) hasn't been pulled. The first step of `/work` should sync local main with remote.

**No external research needed.** This is standard Flutter/Riverpod widget work using existing patterns in the codebase.

**Breakpoint-adjacent testing:** Per `app/CLAUDE.md`, test at 599px, 600px, 601px to verify the single breakpoint transition works cleanly. The old 1199px/1200px boundary goes away.

**Bottom sheet patterns:** Per `app/CLAUDE.md`, all bottom sheets must wrap content in `Flexible` + `SingleChildScrollView`, pin drag handle and buttons outside scroll, constrain to 85% height.

## Dependencies & Risks

- **PR #265 merge required** — The container rename must be on the working branch before implementation starts.
- **Local main divergence** — Local main has transcription commits not yet on remote; remote has container rename not yet local. Need to reconcile before branching.
- **Low risk overall** — This is a UI-only change. No server changes needed. No new API endpoints. The filtering logic stays identical; we're just changing how the user triggers it.
