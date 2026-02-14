---
title: "fix: UI Polish, Overflow Audit & Directory Picker"
type: fix
date: 2026-02-09
---

# fix: UI Polish, Overflow Audit & Directory Picker

## Overview

Audit and fix overflow bugs across the chat UI, replace the plain TextField working directory field in workspace dialogs with the existing vault folder picker, and harden responsive rendering at breakpoint boundaries (600px, 1200px). Add preventive patterns to `app/CLAUDE.md`.

## Motivation

Several UI surfaces have overflow-prone layouts that break at narrow or boundary widths. The workspace dialog uses a raw TextField for working directories, which requires users to know vault-relative paths by memory. The app already has a fully functional `DirectoryPickerDialog` backed by the server's `GET /api/ls` endpoint and a `VaultEntry` model -- we just need to wire it into the workspace form. Finally, the 3-breakpoint layout system in `ChatShell` has edge-case rendering issues around 600px and 1200px where column widths fight for space.

## Scope

| Area | Files | What changes |
|------|-------|-------------|
| Overflow fixes | `new_chat_sheet.dart`, `session_config_sheet.dart`, `chat_screen.dart`, `session_list_item.dart`, `chat_input.dart` | Wrap/constrain overflow-prone rows and columns |
| Directory picker | `workspace_dialog.dart`, `directory_picker.dart` | Replace TextField with picker; add browse button |
| Responsive fixes | `chat_shell.dart`, `session_list_panel.dart`, `chat_screen.dart` | Fix column widths at breakpoint boundaries |
| Prevention | `app/CLAUDE.md` | Add overflow-prevention patterns to conventions |

---

## Part 1: Overflow Fixes

### 1.1 NewChatSheet -- Bottom sheet content can exceed screen height

**File:** `app/lib/features/chat/widgets/new_chat_sheet.dart`

The sheet uses `Column(mainAxisSize: MainAxisSize.min)` as the root, which grows unbounded. On short screens or with a keyboard visible, the content (workspace section + project folder + agent selector + trust chips + start button) can exceed available height. There is no scroll wrapper around the content area.

- [x] **Line 164 (outer Column):** Wrap the content `Column` (between the handle bar and the start-button footer) in a `Flexible` + `SingleChildScrollView` so the sheet scrolls when content exceeds available height. Keep the drag handle and Start Chat button pinned outside the scroll region.
- [x] **Line 216-373 (inner Padding > Column):** This is the block that should become scrollable. Move it inside `Flexible(child: SingleChildScrollView(...))`.
- [x] Add `DraggableScrollableSheet` or constrain with `maxHeight: MediaQuery.of(context).size.height * 0.85` on the outer `Container` (line 157) to prevent the sheet from covering the full screen.

### 1.2 NewChatSheet -- Agent selector Row overflow at narrow widths

**File:** `app/lib/features/chat/widgets/new_chat_sheet.dart`

- [ ] **Lines 337-349 (agent selector Row):** The agent chips use `Row > Expanded` which works for exactly 2 agents. If a third agent is added, or on very narrow screens (~320px), the chips' internal `Row(mainAxisSize: MainAxisSize.min)` with label + description text can clip. Replace the outer `Row` with a `Wrap` with `spacing: Spacing.sm` and `runSpacing: Spacing.sm`, or use `LayoutBuilder` to switch between `Row(Expanded)` for wide and stacked layout for narrow. The `Expanded` wrapper on each chip already helps, but the minimum intrinsic width of agent chips (icon + label + description) may exceed half the available width on 320px screens.

### 1.3 NewChatSheet -- Working directory path text overflow

**File:** `app/lib/features/chat/widgets/new_chat_sheet.dart`

- [ ] **Line 290 (full path subtitle Text):** The full vault-relative path is shown as a subtitle. It has `overflow: TextOverflow.ellipsis` (line 297) which is correct, but the `Expanded` parent starts at line 274. Verify this works at 320px. No change needed if `Expanded` is correctly constraining -- just confirm during testing.

### 1.4 SessionConfigSheet -- No scroll wrapper, keyboard pushes content off-screen

**File:** `app/lib/features/chat/widgets/session_config_sheet.dart`

The sheet uses `Column(mainAxisSize: MainAxisSize.min)` (line 156) with `MediaQuery.of(context).viewInsets.bottom` padding (line 154). When the mention pattern TextField is focused and the keyboard opens, the total content height may exceed available space because there is no scroll wrapper.

- [x] **Lines 156-413 (root Column):** Wrap the children between the drag handle and the save button in a `Flexible` + `SingleChildScrollView`. Keep the drag handle at the top and the save button at the bottom pinned.
- [ ] **Lines 316-331 (SegmentedButton for response mode):** The `SegmentedButton` labels "All Messages" and "Mentions Only" use hardcoded `fontSize: 12` (lines 320, 325). At narrow widths (<360px), these can overflow the segmented button bounds. Add `overflow: TextOverflow.ellipsis` and wrap the `Text` in a `Flexible` or reduce font size for very narrow screens.

### 1.5 SessionConfigSheet -- SegmentedButton trust level text overflow

**File:** `app/lib/features/chat/widgets/session_config_sheet.dart`

- [ ] **Lines 262-284 (trust level SegmentedButton):** Same issue as response mode -- the `ButtonSegment` labels may not fit at very narrow widths. Consider using icons only below 360px, or truncating labels.

### 1.6 ChatScreen -- Embedded toolbar badge row overflow

**File:** `app/lib/features/chat/screens/chat_screen.dart`

The `_buildEmbeddedToolbar` method (line 472) constructs a `Row` containing: session title (Expanded) + agent badge + model badge + working directory indicator + settings button + more button. When all badges are present simultaneously (agent + model + working dir), the Row can overflow before the `Expanded` title absorbs the space, because each badge uses `mainAxisSize: MainAxisSize.min` but has a minimum width.

- [x] **Lines 485-625 (embedded toolbar Row):** Ensure the badge section does not exceed available space. Options: (a) wrap badges in a `Flexible` so they shrink, (b) put all badges in a horizontal `SingleChildScrollView`, or (c) hide the lowest-priority badge (working directory) when space is tight using `LayoutBuilder`.
- [x] **Lines 505-519 (agent badge):** The agent badge `Row(mainAxisSize: MainAxisSize.min)` at line 505 is fine, but it should have `overflow: TextOverflow.ellipsis` on the label `Text` (line 510) in case of long agent names.

### 1.7 ChatScreen -- AppBar title badges overflow on mobile

**File:** `app/lib/features/chat/screens/chat_screen.dart`

- [x] **Lines 791-815 (AppBar title badge Row):** The subtitle row uses `Row(mainAxisSize: MainAxisSize.min)` containing model badge + agent badge + working dir badge. On mobile (where AppBar width is already tight), this can overflow. Wrap in a `SingleChildScrollView(scrollDirection: Axis.horizontal)` or switch to a `Wrap` limited to one line.

### 1.8 ChatScreen -- Empty state suggestion chips hardcoded width

**File:** `app/lib/features/chat/screens/chat_screen.dart`

- [ ] **Lines 1046-1059 (suggestion chips Wrap):** The `Wrap` is correctly used here. Verify chips don't overflow at 320px -- the text "Summarize my recent notes" and "What did I capture today?" are long. If a chip exceeds the available width, it should wrap to the next line. The `Wrap` handles this, but confirm the `ActionChip` label doesn't clip internally.

### 1.9 ChatScreen -- Load earlier segments button overflow

**File:** `app/lib/features/chat/screens/chat_screen.dart`

- [ ] **Lines 902-939 (load-earlier Row):** The `Row(mainAxisSize: MainAxisSize.min)` at line 902 contains an icon + "Load earlier messages" text (`Flexible`) + optional preview text (`Flexible`). Both `Flexible` children with `TextOverflow.ellipsis` look correct. Verify at narrow widths that the Row doesn't overflow when both segments text and preview text are present.

### 1.10 SessionListItem -- Badge accumulation in title row

**File:** `app/lib/features/chat/widgets/session_list_item.dart`

- [x] **Lines 99-186 (title Row with badges):** The title row contains `Expanded(Text)` + up to 4 optional badges (Pending, Setup, Archived, Trust). Each badge has a left margin of `Spacing.xs` (4px). When multiple badges are present (e.g., a Telegram session that is pending initialization and untrusted), the badges can overflow the row. Wrap the badges section in a `Flexible` that shrinks, or move badges to a second row beneath the title when space is limited. Alternatively, use a `Wrap` for the entire row content.

### 1.11 SessionListItem -- Metadata row text overflow

**File:** `app/lib/features/chat/widgets/session_list_item.dart`

- [x] **Lines 209-279 (metadata Row):** The metadata row shows "via Telegram * 2h ago" or "AgentName * 2h ago" in a flat `Row`. Long agent names or source display names can overflow. Wrap the agent/source text in `Flexible` with `TextOverflow.ellipsis`.

### 1.12 ChatInput -- Attachment preview row clipping

**File:** `app/lib/features/chat/widgets/chat_input.dart`

- [ ] **Lines 783-797 (attachment previews):** Uses `SingleChildScrollView(scrollDirection: Axis.horizontal)` which is correct for horizontal scrolling. However, the attachment chips have `ConstrainedBox(maxWidth: 120)` for filenames. Verify this works well. No change likely needed -- just confirm.

### 1.13 DirectoryPickerDialog -- Fixed width dialog doesn't adapt on mobile

**File:** `app/lib/features/chat/widgets/directory_picker.dart`

- [x] **Lines 46-47 (Dialog Container width/height):** The dialog uses `width: 400, height: 500` hardcoded. On screens narrower than 400px (mobile), this causes horizontal overflow. Replace with `ConstrainedBox(constraints: BoxConstraints(maxWidth: 400, maxHeight: 500))` and wrap in `LayoutBuilder` or use `MediaQuery` to cap at `MediaQuery.of(context).size.width * 0.9`.
- [x] **Lines 163-175 (_DirectoryTile trailing Row):** The trailing `Row(mainAxisSize: MainAxisSize.min)` with select button + chevron is fine, but the `title: Text(entry.name)` on long folder names may overflow. Add `overflow: TextOverflow.ellipsis` to the title Text.

---

## Part 2: Workspace Dialog Directory Picker

### Current State

The workspace dialog (`workspace_dialog.dart`) uses `_WorkspaceForm` which renders a plain `TextField` for working directory (line 49-55). Users must type vault-relative paths from memory (e.g., "Projects/my-app").

The app already has:
- `DirectoryPickerDialog` (`directory_picker.dart`) -- full vault browser dialog
- `showDirectoryPicker()` function -- shows dialog, returns selected path
- `vaultDirectoryProvider` (`chat_ui_providers.dart`) -- fetches `GET /api/ls` entries
- `VaultEntry` model (`vault_entry.dart`) -- directory metadata with `hasClaudeMd`, `isGitRepo`
- Server `GET /api/ls` endpoint (`computer/parachute/api/filesystem.py`) -- lists vault directories

### Design

Replace the plain `TextField` with a composite widget: a read-only text field showing the current path + a browse button that opens `DirectoryPickerDialog`. The user can still manually type a path (for power users) but the primary interaction is the picker.

### Tasks

- [x] **2.1** Add `directory_picker.dart` import to `workspace_dialog.dart`
- [x] **2.2** Replace the working directory `TextField` (lines 49-55 in `_WorkspaceForm`) with a `Row` containing:
  - `Expanded(TextField)` -- read-only or editable, shows `dirController.text`
  - `IconButton(icon: Icons.folder_open, onPressed: _browseDirectory)` -- opens picker
- [x] **2.3** Since `_WorkspaceForm` is a `StatelessWidget`, it cannot call `showDirectoryPicker` directly (needs `BuildContext`). Add a `VoidCallback? onBrowseDirectory` parameter to `_WorkspaceForm` and wire it from both `CreateWorkspaceDialog` and `EditWorkspaceDialog`.
- [x] **2.4** In `_CreateWorkspaceDialogState`, add a `_browseDirectory()` method.
- [x] **2.5** Same for `_EditWorkspaceDialogState`.
- [x] **2.6** The `showDirectoryPicker` returns `null` for cancel, empty string for vault root, or a relative path string. Map empty string to empty TextField (vault root), and non-empty to the relative path.
- [ ] **2.7** Test: Create workspace dialog > tap browse > navigate vault > select directory > verify path appears in TextField.
- [ ] **2.8** Test: Edit workspace dialog > change directory via picker > save > verify workspace updates.

### API Status

No new server endpoint needed. The existing `GET /api/ls?path=<relative>` endpoint at `/api/ls` (mounted without prefix in `filesystem.router`) serves directory listings. The Flutter `vaultDirectoryProvider` already calls this via `chatService.listDirectory()`.

---

## Part 3: Responsive Edge-Case Fixes

### 3.1 ChatShell breakpoint transitions

**File:** `app/lib/features/chat/screens/chat_shell.dart`

The breakpoints are defined in `chat_layout_provider.dart`:
- Mobile: < 600px
- Tablet: 600-1199px (2-column: 300px session list + Expanded chat)
- Desktop: >= 1200px (3-column: 220px sidebar + 300px session list + Expanded chat)

#### Issues at 600px boundary

- [x] **Lines 63-83 (_TabletLayout):** At exactly 600px, the tablet layout allocates 300px to session list, leaving only 300px for chat content. The `ChatScreen` in embedded mode renders `_buildEmbeddedToolbar` (48px high row with title + badges + buttons). With all badges present, this toolbar can overflow at 300px content width. **Fix:** Make the session list width responsive: `min(300, constraints.maxWidth * 0.4)` capped at 280 for the tablet breakpoint, giving chat content at least 320px.
- [ ] **Lines 63-83 (_TabletLayout):** When resizing from 599px to 600px, the layout jumps from single-column (full-width session list) to two-column (300px + 300px). This is jarring. Consider a brief cross-fade or AnimatedSwitcher, or lower the tablet breakpoint to 700px to give the two-column layout more room.

#### Issues at 1200px boundary

- [ ] **Lines 94-122 (_DesktopLayout):** At exactly 1200px, the desktop layout allocates 220px + 300px = 520px to sidebars, leaving 680px for chat. This is adequate. However, at 1200px the jump from 2 columns to 3 columns is visually abrupt. Consider using `AnimatedContainer` widths or a brief transition.
- [ ] **Lines 97-99 (workspace sidebar width):** The 220px sidebar works, but at 1200px the sidebar + session list = 520px, which is 43% of the screen. At 1400px+ this ratio is fine, but at 1200-1300px it feels sidebar-heavy. Consider making the sidebar 200px at the low end of desktop and scaling to 240px at wider widths.

### 3.2 SessionListPanel header overflow at narrow widths

**File:** `app/lib/features/chat/widgets/session_list_panel.dart`

- [ ] **Lines 63-111 (header Row):** The header contains title text + search button + archive button + new chat button. At 300px panel width (tablet mode), this is 3 `IconButton` widgets (each ~48px default) + text. Total icon width: ~144px, leaving ~156px for "Archived" text. This fits, but if the panel is narrower (e.g., responsive sidebar), it could overflow. Add `const BoxConstraints(minWidth: 36, minHeight: 36)` to the header `IconButton` widgets and reduce `iconSize` to match the embedded toolbar pattern.

### 3.3 ChatScreen empty state width issues at tablet breakpoint

**File:** `app/lib/features/chat/screens/chat_screen.dart`

- [ ] **Lines 1001-1074 (_buildEmptyState):** The empty state uses `SingleChildScrollView > Center > Padding(xl) > Column`. The suggestion chips, workspace selector, trust level selector, and working directory indicator are centered. At exactly 300px content width (600px tablet), the `Padding(xl)` (24px each side) leaves only 252px for content. The `Wrap` widgets for workspace and trust chips work, but each chip has internal padding (~20px + text). Verify chips don't overflow at 252px. If they do, reduce padding to `Spacing.lg` when embedded or use `LayoutBuilder` to adapt.
- [ ] **Lines 1095-1105 (workspace selector Wrap):** `spacing: 0` with `Padding(horizontal: 3)` on each chip. At 252px, if there are 3+ workspaces with long names, chips wrap correctly but may look cramped. Consider `spacing: Spacing.xs`.

### 3.4 Workspace sidebar text clipping at 220px

**File:** `app/lib/features/chat/screens/chat_shell.dart`

- [x] **Lines 346-424 (_WorkspaceItem):** The workspace item Row contains icon (18px) + spacing (8px) + Expanded(text) + optional popup menu (24px). At 220px sidebar with `Spacing.md` (12px) horizontal padding, the available text width is 220 - 12 - 12 - 18 - 8 - 24 = 146px. This is adequate for most names, but very long workspace names with a subtitle could clip. The `overflow: TextOverflow.ellipsis` on the name text (line 378) is correct. **Verify** the subtitle text (line 382) also has `overflow: TextOverflow.ellipsis` -- it currently does not. Add it.

---

## Part 4: Preventive Patterns for `app/CLAUDE.md`

Add the following to the Conventions section of `app/CLAUDE.md`:

- [x] **4.1** Add "Layout & Overflow Prevention" subsection:
  ```
  ### Layout & Overflow Prevention

  - **Bottom sheets**: Always wrap content between the drag handle and action
    buttons in `Flexible` + `SingleChildScrollView`. Pin the handle and buttons
    outside the scroll region. Constrain max height to
    `MediaQuery.of(context).size.height * 0.85`.
  - **Rows with optional badges**: Use `Flexible` on badge containers or wrap
    in `SingleChildScrollView(scrollDirection: Axis.horizontal)`. Never assume
    a fixed number of badges will fit.
  - **Dialog dimensions**: Never hardcode `width: 400`. Use
    `ConstrainedBox(constraints: BoxConstraints(maxWidth: 400))` so dialogs
    shrink on narrow screens.
  - **Chip/tag lists**: Always use `Wrap` (not `Row`) for lists of chips that
    may grow. This is already noted in MEMORY.md but worth repeating.
  - **SegmentedButton labels**: Keep labels short (<12 chars) or add
    `overflow: TextOverflow.ellipsis` inside a `Flexible`. At <360px, consider
    icon-only segments.
  - **Breakpoint-adjacent widths**: Test at 600px, 601px, 1199px, and 1200px.
    The chat layout transitions are abrupt -- verify no content overflows at
    the exact boundary values.
  - **Embedded toolbar**: The embedded toolbar Row should accommodate
    title + up to 3 badges + 2 icon buttons. If all are present, lower-priority
    badges (working directory) should gracefully hide or shrink.
  ```

- [x] **4.2** Add to Gotchas section:
  ```
  - `Wrap` not `Row` for chip lists that may overflow (workspace chips, trust level chips, badge rows)
  - Bottom sheets without `SingleChildScrollView` will overflow when keyboard opens or content grows
  - `DirectoryPickerDialog` has hardcoded 400x500 dimensions -- needs responsive constraints
  ```

---

## Testing Checklist

- [ ] **T1** Resize macOS window to 320px wide, open New Chat sheet -- verify scrollable, no overflow
- [ ] **T2** Resize to 600px -- verify tablet layout, session list + chat fit without overflow
- [ ] **T3** Resize to 601px -- same check
- [ ] **T4** Resize to 1199px -- verify tablet layout holds
- [ ] **T5** Resize to 1200px -- verify desktop layout with workspace sidebar appears cleanly
- [ ] **T6** Open workspace create dialog at 360px width -- verify directory picker button works
- [ ] **T7** Open workspace edit dialog -- verify existing directory pre-fills and picker navigates
- [ ] **T8** Open session config sheet with mention_only enabled + long mention pattern -- verify sheet scrolls
- [ ] **T9** Create session with agent + workspace + model + working dir -- verify embedded toolbar badges don't overflow at 600px
- [ ] **T10** Session list with 4+ badges on a session item -- verify no horizontal overflow
- [ ] **T11** Run `flutter analyze` -- zero new warnings

---

## Implementation Order

1. **Part 1.13** (DirectoryPickerDialog responsive fix) -- unblocks Part 2
2. **Part 2** (Workspace dialog directory picker) -- high user-impact improvement
3. **Part 1.1-1.5** (Bottom sheet scroll wrappers) -- most impactful overflow fixes
4. **Part 1.6-1.11** (Row overflow fixes) -- lower severity
5. **Part 3** (Responsive breakpoint fixes) -- layout polish
6. **Part 4** (CLAUDE.md patterns) -- after implementation, codify what we learned
7. **Testing** (T1-T11)

---

## Files Modified

| File | Changes |
|------|---------|
| `app/lib/features/chat/widgets/new_chat_sheet.dart` | Scroll wrapper, agent chip Wrap |
| `app/lib/features/chat/widgets/workspace_dialog.dart` | Directory picker integration |
| `app/lib/features/chat/widgets/session_config_sheet.dart` | Scroll wrapper, label overflow |
| `app/lib/features/chat/widgets/directory_picker.dart` | Responsive dialog dimensions |
| `app/lib/features/chat/screens/chat_screen.dart` | Toolbar badge overflow, title badge overflow |
| `app/lib/features/chat/screens/chat_shell.dart` | Responsive sidebar widths, workspace subtitle ellipsis |
| `app/lib/features/chat/widgets/session_list_panel.dart` | Header icon constraints |
| `app/lib/features/chat/widgets/session_list_item.dart` | Badge row overflow, metadata row overflow |
| `app/CLAUDE.md` | Overflow prevention patterns |
