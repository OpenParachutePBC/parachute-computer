# Daily Entry Cleanup Status & Re-transcribe Flow

**Status:** Brainstorm
**Priority:** P2
**Labels:** daily, app, computer
**Issue:** #274

---

## What We're Building

Surface whether voice entries have been through LLM cleanup, and make re-transcribe work correctly through the server pipeline so old entries can be cleaned up.

### The Problem

1. **No visibility into cleanup state** — The server pipeline runs transcription → LLM cleanup, but the entry card shows no indicator once complete. You can't tell if an entry's text is raw Parakeet output or cleaned-up prose.

2. **Old entries stuck as raw** — Entries transcribed locally before the server pipeline existed never went through LLM cleanup. There's no obvious way to send them through it.

3. **"Complete" doesn't mean "cleaned up"** — The server marks entries as `complete` even when cleanup was skipped (no OAuth token) or failed. So `complete` only means "pipeline finished," not "cleanup ran."

4. **Re-transcribe doesn't use the server pipeline** — `_handleTranscribe` downloads audio then runs Parakeet locally on the phone, saves raw text via PATCH, and calls the `_handleEnhance` stub (which does nothing). It never triggers server-side cleanup. This is true even when transcription mode is set to "server."

5. **Cleanup has never actually run** — Data audit of all 18 voice entries shows zero entries at `complete` status, zero with cleanup ever executed. The one entry at `transcribed` status has identical content and raw text — cleanup was attempted but evidently failed silently.

### Data Audit (2026-03-15)

| Metric | Count |
|--------|-------|
| Total entries | 298 |
| Voice entries | 18 |
| Audio file exists on disk (server) | 7 |
| Audio file missing | 11 (9 are test fixtures `Daily/assets/test.wav`) |
| `transcription_status: complete` | **0** |
| `cleanup_status` ever set | **0** |
| `transcription_raw` saved | 1 |

**Audio file locations:**
- **Server-pipeline entries**: Audio at `~/.parachute/daily/assets/{date}/` on the server. Phone doesn't keep a copy.
- **Local-transcribed entries (pre-pipeline)**: Audio path points to phone's local filesystem or test fixture paths. Server has the path string but not the actual file.

### Current State

- Server has `_transcribe_and_cleanup()` which does Whisper transcription → LLM cleanup via `CLEANUP_SYSTEM_PROMPT`
- `_cleanup_transcription()` writes cleaned text to `content`, preserves raw text in `metadata.transcription_raw`
- If cleanup fails or is skipped, status is still set to `complete` — no way to distinguish
- Flutter card shows: spinner while processing, "Cleaning up..." during `transcribed` status, nothing once `complete`
- `_handleEnhance()` in `journal_screen.dart` is a stub: `"AI enhancement coming soon!"`
- `_handleTranscribe()` runs Parakeet locally, ignores transcription mode setting, never triggers server cleanup

## Why This Approach

**Re-transcribe should respect the transcription mode setting.** When set to Server mode, re-transcribe should upload audio to `POST /entries/voice` and let the server do the full pipeline (transcription + cleanup). When set to Local, use Parakeet on-device. When Auto, prefer server if available.

This aligns re-transcribe with the same flow new recordings use — no special path, same code, same pipeline.

**Track cleanup outcome explicitly.** Rather than inferring cleanup status from comparing `content` to `transcription_raw`, add a `cleanup_status` field to entry metadata. Clear, no guesswork.

**Cleanup-only fallback for entries without audio.** For voice entries where the audio file no longer exists (can't re-transcribe), offer a "clean up text" action that sends existing content through `_cleanup_transcription()` without re-transcribing. This requires a new server endpoint but is a small addition.

## Key Decisions

1. **Add `cleanup_status` to entry metadata** — Values: `completed`, `skipped` (no OAuth token), `failed`. Stored alongside `transcription_status` in `metadata_json`. Null means cleanup never ran (pre-pipeline entries).

2. **Surface three visual states on voice entry cards:**
   - **Enhanced** (small ✨ chip) — `cleanup_status == completed`
   - **Raw** (subtle indicator + action button) — cleanup never ran or was skipped/failed
   - **Processing** (spinner) — already shown, no change needed

3. **Re-transcribe respects transcription mode setting** — Server mode → upload to `POST /entries/voice` (full pipeline). Local mode → Parakeet on-device + call cleanup endpoint. Auto → prefer server if available. Currently `_handleTranscribe` always runs locally regardless of setting.

4. **New server endpoint: `POST /entries/{id}/cleanup`** — Runs `_cleanup_transcription()` on existing content. Used for: (a) entries where audio is gone, (b) local mode re-transcribe follow-up, (c) the fallback "clean up text" action.

5. **Wire up `_handleEnhance`** — Replace the stub with a call to the cleanup endpoint. This becomes the "clean up text" action for entries that already have content but no cleanup.

6. **Backfill is manual, one-by-one** — No batch processing for now. User taps re-transcribe (or clean up) on entries they care about.

## Scope

### Server (`computer/`)
- `_cleanup_transcription()`: Write `cleanup_status` to metadata (`completed`, `skipped`, `failed`)
- New endpoint `POST /entries/{id}/cleanup`: Run cleanup on existing entry content
- Keep `transcription_status: complete` behavior (pipeline finished) — the new field is orthogonal

### Flutter (`app/`)
- `JournalEntry` model: Parse `cleanup_status` from server response metadata
- `JournalEntryCard`: Show enhanced/raw indicator for voice entries
- `_handleTranscribe()`: Respect transcription mode setting — use server pipeline when in Server/Auto mode
- `_handleEnhance()`: Replace stub with call to `POST /entries/{id}/cleanup`
- Show appropriate action on cards: "Re-transcribe" (has audio) or "Clean up" (content only, no audio)

### Not in scope
- Batch re-transcription
- UI polish pass (separate brainstorm)
- Title generation from content

## Open Questions

1. **Should re-transcribe create a new entry or update in place?** Server `POST /entries/voice` creates a new entry. For re-transcribe we'd want to update the existing one. May need a new endpoint or a `replace_entry_id` parameter.
