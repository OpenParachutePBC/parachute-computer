---
title: "Workspace Context Bar — Unified Container Navigation"
date: 2026-03-15
issue: 266
labels: [app, chat, enhancement, P2]
---

# Workspace Context Bar

## Problem

Container/workspace switching has three different implementations depending on screen width:

- **Mobile** (<600px): filter chip in session list header → bottom sheet
- **Tablet** (600–1199px): same filter chip → bottom sheet
- **Desktop** (≥1200px): dedicated 220px `_ContainerEnvSidebar`

The richest version (sidebar) lives behind a 1200px breakpoint that's rarely hit — the primary usage is tablet and mobile. The chip-in-header approach treats containers as a filter on a flat list, when what they really are is the place you're working in.

Additionally, unnamed containers shouldn't surface in the UI — only named ones. Naming is the explicit act that signals intent to reuse a workspace.

## Approach: Workspace Context Bar

Kill the breakpoint-dependent sidebar entirely. Replace it with a **workspace context bar** at the top of the session list that works identically everywhere.

### What It Looks Like

Default state (no workspace selected):
```
┌─────────────────────────────┐
│ ▼ All Chats            ⚙ + │  ← Workspace context bar (tappable)
│   12 conversations          │
├─────────────────────────────┤
│ Session 1                   │
│ Session 2                   │
│ ...                         │
└─────────────────────────────┘
```

Tap the workspace name → picker opens:
```
┌─────────────────────────────┐
│ Choose Workspace            │
├─────────────────────────────┤
│ ○ All Chats          (24)  │
│ ● Parachute Dev      (8)   │  ← named containers only
│ ○ LVB Content        (3)   │
│ ○ Woven Web          (5)   │
├─────────────────────────────┤
│ + New Workspace             │
└─────────────────────────────┘
```

With workspace selected:
```
┌─────────────────────────────┐
│ ▼ Parachute Dev    📁  ⚙ + │  ← Name + Files + Settings + New
│   8 conversations           │
├─────────────────────────────┤
│ Session 1                   │
│ Session 2                   │
│ ...                         │
└─────────────────────────────┘
```

### Key Decisions

1. **Named containers only** in the workspace picker. Unnamed sandboxed sessions appear in "All Chats" but never clutter the picker.

2. **Two layout modes, not three.** Remove the 1200px desktop breakpoint entirely:
   - <600px: single column (session list → push to chat)
   - ≥600px: two columns (session list + chat content)

3. **Same widget everywhere.** The workspace context bar is the same component on mobile, tablet, and desktop. The picker is a bottom sheet on mobile/tablet, a popover on desktop.

4. **Quick actions in the bar.** When a workspace is selected, the context bar shows Files (📁) and Settings (⚙) icons — one tap away, no sidebar needed.

5. **Container promotion flow.** When in a session with an unnamed container, session settings shows "Name this workspace" — the act that makes it appear in the picker.

## Phased Implementation

### Phase 1 — Workspace Context Bar widget
- Create `WorkspaceContextBar` widget replacing the filter chip in `SessionListPanel`
- Dropdown/bottom sheet picker showing named containers + "All Chats"
- Same filtering logic (`activeContainerProvider`), better presentation
- **Files touched:** new widget, `session_list_panel.dart`

### Phase 2 — Kill the Desktop Sidebar
- Remove `_ContainerEnvSidebar` from `chat_shell.dart`
- Change desktop layout from 3-column to 2-column
- Remove the 1200px breakpoint — only 600px remains
- The workspace context bar handles everything the sidebar did
- **Files touched:** `chat_shell.dart`, `chat_layout_provider.dart`

### Phase 3 — Container Promotion Flow
- In `SessionConfigSheet`, when session has unnamed container, show "Name this workspace"
- Naming calls the container rename/update API
- Newly-named container immediately appears in workspace picker
- **Files touched:** `session_config_sheet.dart`, container providers

### Phase 4 — Quick Access Actions
- Add Files button → opens `ContainerFileBrowserScreen`
- Add Settings button → container settings (core memory, rename, delete)
- Only visible when a specific workspace is selected (not "All Chats")
- **Files touched:** workspace context bar widget, routing

## Why This Approach

1. **One interaction pattern everywhere** — no breakpoint surprises
2. **Eliminates a breakpoint** — three layout modes → two, real simplification
3. **Named-only is natural** — unnamed sandboxes stay invisible in the picker
4. **Container promotion becomes obvious** — "Name this workspace" in session settings
5. **Files and settings always one tap away** — no sidebar needed

## Alternatives Considered

### Workspace Rail (VS Code style)
48px icon rail on the left edge showing workspace initials. Works on tablet but still creates a mobile-vs-tablet split. Icon-based UI can feel cryptic.

### Workspaces Tab (promoted to bottom nav)
Fourth tab showing workspace cards. Adds navigation complexity, forces two-step flow, doesn't solve "where am I" within Chat tab, takes a bottom nav slot.

## Discussion Notes

- Current desktop sidebar is rarely seen since primary usage is tablet/mobile
- Navigation feels awkward with breakpoint-dependent behavior
- Naming a container is the act that signals intent to reuse
- This brainstorm follows the Container Primitive rename (#264 / PR #265)
