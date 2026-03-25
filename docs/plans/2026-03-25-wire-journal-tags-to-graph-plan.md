---
issue: 343
title: Wire journal entry tags to graph via TagService
created: 2026-03-25
status: plan
---

# Wire Journal Entry Tags to Graph via TagService

## Current State

Tags on journal entries flow: `EntryEditModal._tags` → `JournalEntry.copyWith(tags:)` → `onSave` callback → `DailyApiService.updateEntry(metadata: {tags: [...]})` → server stores in `Note.metadata_json` → backend startup migration converts metadata tags to TAGGED_WITH graph edges.

This works but is indirect — the app never talks to the graph tag system directly. The `TagService` and `tagServiceProvider` exist but are unused.

## Design

**Dual-write with graph as source of truth when online:**

1. **On save**: continue sending tags in metadata (backward compat), AND call TagService to sync graph edges (add new, remove deleted)
2. **On load**: when server available, fetch tags from TagService (graph) instead of metadata
3. **Offline**: fall back to metadata tags; queue tag sync operations for when server reconnects

This is incremental — no big-bang migration, no breaking changes.

## Implementation

### Phase 1: Sync tags to graph on save (journal_screen.dart)

In the `onSave` callback (~line 1461), after the existing `api.updateEntry()` call, diff the original vs updated tags and call TagService:

```dart
onSave: (updatedEntry) async {
  final api = ref.read(dailyApiServiceProvider);
  // ... existing updateEntry call (keep for metadata backward compat) ...

  // Sync tags to graph
  final tagService = ref.read(tagServiceProvider);
  final oldTags = Set<String>.from(entry.tags ?? []);
  final newTags = Set<String>.from(updatedEntry.tags ?? []);
  final added = newTags.difference(oldTags);
  final removed = oldTags.difference(newTags);
  for (final t in added) {
    tagService.addTag('note', updatedEntry.id, t);  // fire-and-forget
  }
  for (final t in removed) {
    tagService.removeTag('note', updatedEntry.id, t);  // fire-and-forget
  }
},
```

Fire-and-forget is fine here — the metadata write is the durable path, and the backend migration will catch any missed graph edges on next startup.

**File**: `app/lib/features/daily/journal/screens/journal_screen.dart`

### Phase 2: Load tags from graph when available (journal_screen.dart)

Before opening `EntryEditModal`, if server is available, fetch graph tags to ensure we show the canonical set:

```dart
// Before opening modal:
final isOnline = ref.read(isServerAvailableProvider);
var displayEntry = entry;
if (isOnline) {
  final tagService = ref.read(tagServiceProvider);
  final graphTags = await tagService.getEntityTags('note', entry.id);
  if (graphTags.isNotEmpty || (entry.tags ?? []).isNotEmpty) {
    displayEntry = entry.copyWith(tags: graphTags.isNotEmpty ? graphTags : null);
  }
}
// Then open EntryEditModal with displayEntry
```

**File**: `app/lib/features/daily/journal/screens/journal_screen.dart`

### Phase 3: TagInput autocomplete from graph (tag_input.dart)

Currently `TagInput.suggestions` is passed in statically. Add optional `tagServiceProvider` lookup for autocomplete:

- In `EntryEditModal._buildTagPicker`, pass `allTags` fetched from `tagService.listTags()` as suggestions
- This makes the autocomplete show all tags used across the system, not just locally known ones

**Files**: `app/lib/features/daily/journal/widgets/entry_edit_modal.dart`

### What we're NOT doing

- **No separate tag queue**: Tag sync is fire-and-forget alongside the existing metadata save. Backend migration handles gaps. Building a separate PendingTagQueue would be over-engineering given the migration safety net.
- **No removing metadata tags**: Keep tags in metadata for offline fallback. The backend migration is idempotent and handles the metadata→graph conversion.
- **No brain entity tags**: Not using brain entities right now.
- **No cross-entity tag browser**: Separate issue.

## Files Changed

| File | Change |
|------|--------|
| `app/lib/features/daily/journal/screens/journal_screen.dart` | Import tagServiceProvider, add graph sync in onSave, fetch graph tags before modal |
| `app/lib/features/daily/journal/widgets/entry_edit_modal.dart` | Accept and pass through allTags for autocomplete |
| `app/lib/core/widgets/tag_input.dart` | No changes needed (already accepts suggestions) |

## Acceptance Criteria

- [ ] Adding/removing tags in EntryEditModal calls TagService add/remove
- [ ] Tags loaded from graph when server available
- [ ] Offline: tags still work via metadata fallback
- [ ] `tagServiceProvider` is consumed (not dead code)
- [ ] Existing entries with local tags still work (backend migration handles graph sync)
- [ ] Autocomplete shows system-wide tags from graph

## Risk

**Low**. Dual-write is additive — if TagService calls fail, metadata path still works and backend migration catches up. No schema changes, no breaking API changes.
