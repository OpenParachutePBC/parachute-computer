---
title: "Daily Entry Cleanup Status & Re-transcribe Flow"
type: feat
date: 2026-03-15
issue: 274
---

# Daily Entry Cleanup Status & Re-transcribe Flow

Surface whether voice entries have been through LLM cleanup, fix re-transcribe to use the server pipeline when configured, and add a cleanup-only endpoint for entries without audio.

## Problem Statement

1. **Cleanup has never successfully run** — Data audit shows 0/18 voice entries at `complete` status, 0 with `cleanup_status` ever set. The pipeline silently skips cleanup when OAuth token is missing and still marks entries `complete`.

2. **Re-transcribe ignores transcription mode** — `_handleTranscribe` always runs Parakeet locally, even when settings say Server. It never triggers the server cleanup pipeline.

3. **No visibility into cleanup state** — Entry cards show no indicator for whether content is raw Parakeet output or cleaned-up prose. `complete` only means "pipeline finished," not "cleanup ran."

4. **`_handleEnhance` is a stub** — Shows "AI enhancement coming soon!" snackbar. Never calls anything.

## Proposed Solution

### Phase 1: Server — Track cleanup status & add cleanup endpoint

**1a. `_cleanup_transcription()` writes `cleanup_status` to metadata**

Currently the function marks `transcription_status: complete` regardless of outcome. Add a `cleanup_status` field:
- `completed` — cleanup ran and wrote cleaned text
- `skipped` — no OAuth token available
- `failed` — cleanup threw an exception
- `null` — cleanup never ran (pre-pipeline entries)

Write it via `_update_entry_transcription_status()` alongside `transcription_status`.

Files: `computer/modules/daily/module.py`
- `_cleanup_transcription()` (line 262): Set `cleanup_status` in metadata at each exit path
- `_update_entry_transcription_status()` (line 327): Accept optional `cleanup_status` param, write to metadata_json

**1b. New endpoint: `POST /entries/{id}/cleanup`**

Runs `_cleanup_transcription()` on an existing entry's content. Used for:
- Entries where audio is gone (can't re-transcribe, but can clean up text)
- Local-mode re-transcribe follow-up (Parakeet transcribed on-device, now clean up server-side)
- The "Clean up" action button on voice entry cards

Implementation:
- Read entry content from graph
- Call `_cleanup_transcription(graph, entry_id, content)`
- Return updated entry

Files: `computer/modules/daily/module.py`
- New route in `_register_routes()`, after `create_voice_entry`

**1c. `POST /entries/voice` — add `replace_entry_id` parameter**

Currently `POST /entries/voice` always creates a new entry. For re-transcribe, we need to update an existing entry in place.

Add optional `replace_entry_id: str | None = Form(None)` parameter:
- If provided: skip `create_entry()`, instead update the existing entry's content, audio_path, and metadata
- Kick off `_transcribe_and_cleanup()` on the existing entry_id
- Return the existing entry_id (not a new one)

This avoids creating a separate `/entries/{id}/retranscribe` endpoint — same code path, one extra parameter.

Files: `computer/modules/daily/module.py`
- `create_voice_entry()` route handler (line 1396): Add parameter, branch logic

### Phase 2: Flutter — Parse cleanup status & fix re-transcribe

**2a. Parse `cleanup_status` in model**

Add `CleanupStatus` enum to `entry_metadata.dart`: `completed`, `skipped`, `failed`.

Add `cleanupStatus` field to `JournalEntry`. Parse from server JSON metadata (`metadata.cleanup_status`).

Add computed properties:
- `isCleanedUp` → `cleanupStatus == CleanupStatus.completed`
- `needsCleanup` → voice entry where `cleanupStatus` is null, `skipped`, or `failed`

Files:
- `app/lib/features/daily/journal/models/entry_metadata.dart`: Add `CleanupStatus` enum
- `app/lib/features/daily/journal/models/journal_entry.dart`: Add field, computed props, parse in `fromServerJson`

**2b. Show cleanup indicator on voice entry cards**

Voice entries show one of:
- ✨ small chip when `isCleanedUp` — subtle "Enhanced" label
- "Raw" indicator + action button when `needsCleanup` — tap triggers cleanup or re-transcribe
- Spinner (existing) when `isServerProcessing` — no change needed

Keep it minimal — just enough to know the state.

Files:
- `app/lib/features/daily/journal/widgets/journal_entry_card.dart`: Add indicator in the status area (near existing cleanup indicator logic, ~line 112-151)

**2c. Fix `_handleTranscribe` to respect transcription mode**

Mirror the pattern from `_addVoiceEntry` (line 500-534) which already reads `transcriptionModeProvider` and dispatches:

```
Server mode → upload audio to POST /entries/voice with replace_entry_id → poll for completion
Local mode  → Parakeet on-device → PATCH content → call POST /entries/{id}/cleanup
Auto mode   → prefer server if available, fall back to local
```

The current code (line 959) always runs locally. Replace with mode-aware dispatch.

When using server mode for re-transcribe:
1. Download audio from server (existing code handles this)
2. Upload to `POST /entries/voice` with `replace_entry_id=entry.id`
3. Start polling via `_startPollingEntry(entry.id)` (existing infrastructure)

When using local mode:
1. Run Parakeet locally (existing code)
2. PATCH content to server (existing code)
3. Call `POST /entries/{id}/cleanup` for LLM cleanup
4. Start polling (or just update UI on cleanup response)

Files:
- `app/lib/features/daily/journal/screens/journal_screen.dart`: Rewrite `_handleTranscribe()` (~line 959)

**2d. Wire `_handleEnhance` to cleanup endpoint**

Replace the stub with a call to `POST /entries/{id}/cleanup`:
1. POST to cleanup endpoint
2. Show "Cleaning up..." state on card
3. Start polling or update UI on response

Files:
- `app/lib/features/daily/journal/screens/journal_screen.dart`: Replace `_handleEnhance()` (line 1099)

**2e. Add `replaceEntryId` to API service**

Add optional parameter to `uploadVoiceEntry()` and a new `cleanupEntry()` method.

Files:
- `app/lib/features/daily/journal/services/daily_api_service.dart`:
  - `uploadVoiceEntry()`: Add optional `replaceEntryId` field, include in multipart form
  - New `cleanupEntry(String entryId)`: POST to `/entries/{id}/cleanup`

**2f. Smart action button on cards**

Show contextual action on voice entry cards:
- Has audio + `needsCleanup` → "Re-transcribe" (full pipeline)
- No audio + `needsCleanup` → "Clean up" (text-only cleanup)
- `isCleanedUp` → no action button (already done)

Files:
- `app/lib/features/daily/journal/widgets/journal_entry_card.dart`: Update menu/actions

## Acceptance Criteria

- [x] `_cleanup_transcription()` writes `cleanup_status` to entry metadata (completed/skipped/failed)
- [x] New `POST /entries/{id}/cleanup` endpoint runs cleanup on existing entry content
- [x] `POST /entries/voice` accepts `replace_entry_id` to update in place instead of creating new
- [x] Flutter parses `cleanup_status` from server metadata
- [x] Voice entry cards show enhanced (✨) or raw indicator
- [x] Re-transcribe respects transcription mode setting (server/local/auto)
- [x] `_handleEnhance` calls cleanup endpoint instead of showing stub snackbar
- [x] Cards show "Re-transcribe" (has audio) or "Clean up" (no audio) action for raw entries
- [x] Polling resolves correctly after server-mode re-transcribe

## Technical Considerations

**Re-transcribe polling**: Server-mode re-transcribe reuses the existing polling infrastructure (`_startPollingEntry`). The poll checks `isServerProcessing` which looks at `transcription_status`. Since `replace_entry_id` reuses the entry, we need to set status back to `processing` on the server side to trigger the poll cycle.

**OAuth token for cleanup**: `_cleanup_transcription` currently skips silently if no token. With `cleanup_status: skipped`, the UI can surface this and the user knows to check their setup. The cleanup endpoint should return an appropriate error if token is missing rather than silently skipping.

**Audio availability**: `journal.getAudioPath(entry.id)` returns the stored path, but the file may not exist on disk (11/18 voice entries have missing audio). The card action should check audio existence before offering "Re-transcribe" vs "Clean up". Existing `_handleTranscribe` already handles missing audio with an error snackbar — we can improve this by proactively checking.

**Backward compatibility**: `cleanup_status: null` means "never ran" — safe default for all existing entries. No migration needed.

## Not In Scope

- Batch re-transcription
- UI polish pass (separate brainstorm)
- Title generation from content
- Fixing the 2 entries stuck at `processing` status (manual fix, not a feature)
