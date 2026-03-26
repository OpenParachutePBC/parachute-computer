---
title: Journal Entry Detail/Edit Screen Convergence
status: brainstorm
priority: P2
labels: daily, app
date: 2026-03-25
issue: 347
---

# Journal Entry Detail/Edit Screen Convergence

## What We're Building

A unified entry detail screen that replaces both `ComposeScreen` (text entries) and `EntryEditModal` (voice/photo/handwriting entries). The new screen opens in **read mode by default** and transitions to edit mode on explicit user action.

This also resolves the false "Discard changes?" dialog, brings tag UI to all entry types, and creates a consistent experience regardless of how the entry was created.

## Why

The current journal has two detail/edit surfaces that evolved independently:

- **ComposeScreen** (full-screen, text entries only): Has markdown toolbar and preview toggle, but no tag UI. Opens directly in edit mode — back button triggers "Discard changes?" even when nothing was changed. The discard check doesn't compare against the original content.
- **EntryEditModal** (bottom sheet, voice/photo/handwriting): Has tag UI and auto-save drafts, but feels dated as a modal. No discard dialog.

This divergence means:
- Text notes have no way to add tags
- Tapping any entry puts you straight into editing with no read-first experience
- The discard dialog fires incorrectly for text notes
- Two codepaths to maintain for fundamentally the same operation

## Key Decisions

1. **Read mode first, edit on action.** Tapping an entry opens the detail screen in read mode — rendered markdown, visible tags, audio player for voice entries. An "Edit" button switches to edit mode. Back from read mode has no discard dialog. Back from edit mode only warns if content actually changed (diff against original).

2. **Full-screen, not bottom sheet.** Lean toward ComposeScreen's full-screen layout. The bottom sheet pattern constrains voice entries unnecessarily and feels inconsistent with text entries.

3. **Drop markdown toolbar for now.** Not actively used. Can re-add later if demand surfaces. The edit mode is a plain text field.

4. **Explicit save, no auto-save drafts.** Simpler to reason about. Auto-save can be layered on later if needed. The existing `PendingEntryQueue` handles offline save failures.

5. **Tags visible in both modes.** Read mode shows tag chips (read-only). Edit mode shows `TagInput` widget for adding/removing. All entry types get tags.

6. **Entry-type sections render conditionally.** Audio player for voice entries, image preview for photo entries, etc. — these are sections within the same screen, not different screens.

## Current Architecture

```
Tap entry → _showEntryDetail()
  ├── text entry → ComposeScreen (full-screen, edit mode)
  ├── voice/photo/handwriting → EntryEditModal (bottom sheet, edit mode)
  └── preamble/imported → read-only

Long-press → action sheet → "Edit" → inline editing in list row
```

### Files involved:
- `app/lib/features/daily/journal/screens/compose_screen.dart` — full-screen text editor
- `app/lib/features/daily/journal/widgets/entry_edit_modal.dart` — modal for non-text entries
- `app/lib/features/daily/journal/screens/journal_screen.dart` — orchestrates navigation + editing state
- `app/lib/core/widgets/tag_input.dart` — reusable tag input widget
- `app/lib/core/services/tag_service.dart` — graph-native tag API client

## Target Architecture

```
Tap entry → EntryDetailScreen (read mode)
  ├── Shows: rendered content, tags, metadata, type-specific sections
  └── "Edit" button → switches to edit mode
      ├── Plain text editing (title + content)
      ├── TagInput for tag editing
      └── Save button → server update + tag sync
          Back → discard check (only if actual changes)

Long-press → action sheet (unchanged, "Edit" could navigate to detail screen in edit mode)
```

### Single screen, two modes:
- **Read mode**: rendered markdown, read-only tag chips, audio player, metadata
- **Edit mode**: plain text fields, editable TagInput, save/cancel actions

## Open Questions

1. **What happens to inline list editing?** The long-press → "Edit" flow that makes the row itself editable. Keep it as a quick-edit shortcut, or route to the detail screen in edit mode?

2. **ComposeScreen for new entries?** When creating a brand new text entry (compose from scratch), does it go straight to the detail screen in edit mode, or is there still a separate compose flow? Probably the same screen with `entry: null`.

3. **Draft recovery from SharedPreferences?** EntryEditModal currently saves drafts to SharedPreferences on every keystroke. We're dropping auto-save, but should we migrate/clear existing drafts so users don't lose in-flight work?
