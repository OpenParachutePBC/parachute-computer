---
title: Journal Entry Detail/Edit Screen Convergence
status: plan
priority: P2
labels: daily, app
date: 2026-03-25
issue: 347
---

# Journal Entry Detail/Edit Screen Convergence

## Goal

Replace both `ComposeScreen` (text entries) and `EntryEditModal` (voice/photo/handwriting) with a single `EntryDetailScreen` that opens in **read mode** and transitions to **edit mode** on user action.

## Current State

Two divergent surfaces:

| | ComposeScreen | EntryEditModal |
|---|---|---|
| **Entry types** | Text only | Voice, photo, handwriting |
| **Layout** | Full-screen Scaffold | Bottom sheet modal |
| **Opens in** | Edit mode always | Edit mode always |
| **Tags** | None | TagInput widget |
| **Discard dialog** | Yes (broken — fires even without changes) | No |
| **Markdown** | Toolbar + preview toggle | Plain text only |
| **Audio player** | No | Yes |
| **Draft auto-save** | Yes (composeDraftProvider) | Yes (SharedPreferences) |
| **Save flow** | Returns ComposeResult via Navigator.pop | Calls onSave callback |

**Call sites:**
1. `journal_screen.dart:_showEntryDetail()` — routes text → ComposeScreen, others → EntryEditModal
2. `journal_input_bar.dart:_openComposeScreen()` — new text entries → ComposeScreen

## Target State

One `EntryDetailScreen` with two modes:

### Read Mode (default on tap)
- Rendered markdown content (reuses ComposeScreen's `_buildPreview` style)
- Read-only tag chips
- Audio player for voice entries (reuses `_buildAudioPlayer` from journal_screen)
- Entry metadata: type icon, duration badge, timestamp
- "Edit" button in app bar → transitions to edit mode
- Back button → no dialog, just pops

### Edit Mode
- Plain text title + content fields (like EntryEditModal's, no markdown toolbar)
- Editable TagInput widget with autocomplete suggestions
- Audio player still visible for voice entries
- "Save" button in app bar
- Back button → discard dialog ONLY if content actually changed (diff against original)
- On save: server update + tag sync (reuses existing save logic from journal_screen)

### For New Entries (ComposeScreen replacement)
- `journal_input_bar.dart` opens `EntryDetailScreen` directly in edit mode with no entry
- Same screen, same code, `entry: null` means create mode
- Returns `ComposeResult` via Navigator.pop (same pattern as current ComposeScreen)

## Implementation Steps

### Step 1: Create `EntryDetailScreen`

**New file:** `app/lib/features/daily/journal/screens/entry_detail_screen.dart`

```dart
class EntryDetailScreen extends ConsumerStatefulWidget {
  final JournalEntry? entry;          // null = new entry (compose mode)
  final bool startInEditMode;         // true for new entries, false for viewing existing
  final List<String> allTags;         // system-wide tags for autocomplete
  final Widget? audioPlayer;          // audio player widget for voice entries

  // Callback for saving (editing existing entry)
  final Future<void> Function(JournalEntry updatedEntry)? onSave;
}
```

**State:**
- `_isEditing` — starts at `widget.startInEditMode`
- `_titleController`, `_contentController` — initialized from entry
- `_tags` — initialized from entry.tags
- `_originalTitle`, `_originalContent`, `_originalTags` — for change detection

**Read mode build:**
- AppBar: back button, "Edit" action button (if editable)
- Body: type header (icon + duration) → audio player (if voice) → rendered markdown → tag chips (read-only)
- Reuse the markdown rendering style from ComposeScreen's `_buildPreview`

**Edit mode build:**
- AppBar: back button (with discard check), "Save" action button
- Body: title TextField → content TextField → TagInput
- Audio player still visible above content if voice entry

**Discard check:**
- Compare `_titleController.text` vs `_originalTitle`, `_contentController.text` vs `_originalContent`, `_tags` vs `_originalTags`
- Only show dialog if any differ

**Save flow for existing entries:**
- Call `widget.onSave(updatedEntry)` — journal_screen passes the same save+tag-sync closure it currently gives EntryEditModal
- Pop on success

**Save flow for new entries:**
- Pop with `ComposeResult(title, content)` — same as current ComposeScreen

### Step 2: Wire `_showEntryDetail` to use `EntryDetailScreen`

**File:** `app/lib/features/daily/journal/screens/journal_screen.dart`

Changes to `_showEntryDetail()`:
- Remove the text-entry branch that routes to ComposeScreen
- Remove the `showModalBottomSheet` call for EntryEditModal
- All entry types now push `EntryDetailScreen` via `Navigator.push`
- Tag fetching logic stays (fetch graph tags + allTags before opening)
- The `onSave` callback stays (server update + tag sync + invalidate provider)
- Pass `audioPlayer` for voice entries

Delete `_openComposeForEdit()` — no longer needed.

### Step 3: Wire `journal_input_bar.dart` to use `EntryDetailScreen`

**File:** `app/lib/features/daily/journal/widgets/journal_input_bar.dart`

Change `_openComposeScreen()`:
- Push `EntryDetailScreen(entry: null, startInEditMode: true)` instead of `ComposeScreen`
- Same result handling — pop returns `ComposeResult`

### Step 4: Delete old files

- Delete `app/lib/features/daily/journal/screens/compose_screen.dart`
- Delete `app/lib/features/daily/journal/widgets/entry_edit_modal.dart`
- Delete `app/lib/features/daily/journal/providers/compose_draft_provider.dart` (no more auto-save)
- Delete `app/lib/features/daily/journal/widgets/markdown_text_controller.dart` (only used by ComposeScreen toolbar)
- Clean up any orphaned imports

### Step 5: Clean up inline editing

The long-press → "Edit" action in `_showEntryActions()` currently calls `_startEditing()` which toggles inline editing in the list row. Change it to open `EntryDetailScreen` in edit mode instead, for consistency.

## Files Changed

| File | Action | What |
|------|--------|------|
| `screens/entry_detail_screen.dart` | **Create** | New unified detail/edit screen |
| `screens/journal_screen.dart` | **Edit** | Route all entries to EntryDetailScreen, remove `_openComposeForEdit` |
| `widgets/journal_input_bar.dart` | **Edit** | Use EntryDetailScreen for new entries |
| `screens/compose_screen.dart` | **Delete** | Replaced by EntryDetailScreen |
| `widgets/entry_edit_modal.dart` | **Delete** | Replaced by EntryDetailScreen |
| `providers/compose_draft_provider.dart` | **Delete** | No more auto-save |
| `widgets/markdown_text_controller.dart` | **Delete** | Markdown toolbar removed |

## What We're NOT Doing

- No markdown editing toolbar (can add later)
- No auto-save drafts (explicit save only)
- No changes to the entry list view (`journal_entry_row.dart`)
- No changes to the backend or tag API
- No changes to entry creation flow beyond routing to new screen

## Acceptance Criteria

- [ ] Tapping any entry type opens `EntryDetailScreen` in read mode
- [ ] Read mode shows rendered markdown, tags, audio player (voice entries)
- [ ] "Edit" button switches to edit mode with editable fields + TagInput
- [ ] Back from read mode → no discard dialog
- [ ] Back from edit mode → discard dialog only if content actually changed
- [ ] Saving entry updates server + syncs tags to graph (same as before)
- [ ] New text entries from input bar open EntryDetailScreen in edit mode
- [ ] ComposeScreen and EntryEditModal are deleted
- [ ] Long-press → "Edit" opens detail screen in edit mode (not inline editing)
