---
title: Daily offline resilience — durable audio staging + upload-aware pending queue
type: feat
date: 2026-03-04
issue: 176
---

# Daily Offline Resilience — Durable Audio Staging + Upload-Aware Pending Queue

## Audit Findings

Before designing the fix, here is the current offline behaviour per entry type:

| Entry type | Creation | Read | Edit |
|---|---|---|---|
| Text | ✅ `PendingEntryQueue` — queued offline, flushed on journal load | ✅ SQLite cache | ⚠️ Draft saved to SharedPreferences, requires manual retry |
| Voice | ❌ Audio upload fails → local Android temp path stored on server; temp evictable | ✅ SQLite cache | ⚠️ Same as text |
| Photo | ⚠️ Photo file persisted in app documents; entry queued; photo path sent as-is | ✅ SQLite cache | ⚠️ Same as text |
| Re-connection flush | ❌ Only fires when user navigates to a day, not on connectivity change | | |

The most critical gap is **voice entries**: when the server is unreachable, the audio upload silently fails, the local temp path is embedded in the entry, and the temp file can be evicted by Android at any time. When `PendingEntryQueue` later flushes the entry, it sends the meaningless local path to the server.

## Proposed Solution

### Part A — Durable audio staging (one-liner fix, big safety gain)

Before attempting the upload, move the recorded WAV from `getTemporaryDirectory()` to a stable app-documents directory:
```
{appDocDir}/parachute/pending-audio/{timestamp}.wav
```
Android cannot evict files in app documents. This is a safe pre-condition for everything else and costs almost nothing.

**File**: `app/lib/features/daily/recorder/services/transcription/streaming_audio_recorder.dart`
- After `stopRecording()`, call `File.copy(stagedPath)` then `tempFile.delete()` before returning the path

### Part B — Upload-aware PendingEntryQueue

The core fix: `PendingEntryQueue` already stores the `audioPath` field. Change the flush logic so that if `audioPath` is a local file path (i.e. starts with `/`), the flush:
1. Attempts `api.uploadAudio(File(audioPath))`
2. On success: uses the server URL as the entry's `audio_path`, deletes the staged local file
3. On failure: keeps the entry in queue (server never receives the local path)

This makes voice entry creation atomic from the server's perspective: the server only sees the entry once both the audio and the metadata are ready.

**File**: `app/lib/features/daily/journal/services/pending_entry_queue.dart`
- Add an `uploadAudio` step in `flush()` for items where `audioPath` is a local path

### Part C — Connectivity-triggered flush (optional, lower priority)

Today, `PendingEntryQueue.flush()` only fires when the user navigates to a journal day. A simple improvement: also flush when the periodic health check transitions from offline → online.

**File**: `app/lib/core/providers/backend_health_provider.dart` + `app/lib/features/daily/journal/providers/journal_providers.dart`
- Watch `periodicServerHealthProvider` in `JournalNotifier`; when status transitions to `connected`, call `_flushPendingQueue()`

This is a `ref.listen` pattern already used elsewhere in the codebase.

### Out of scope

- **Entry edits while offline**: drafts work and require manual re-submit. Acceptable UX for now.
- **PATCH existing server entry with server audio path**: only needed if the server is reachable but audio upload fails while entry creation succeeds — a narrow race condition. Not worth the complexity.
- **Photo upload retry**: photos live in app documents (not temp), so eviction isn't a risk. The current local-path-in-entry approach works for single-device use. Can be improved separately.

## Acceptance Criteria

- [x] After recording a voice entry offline, the audio WAV is in app documents (not temp)
- [x] The `PendingEntryQueue` entry stores the staged local path, not the server URL
- [x] On reconnect + journal load, the audio uploads first; the entry is then created with the server path
- [x] The server never stores a local Android path (e.g. `/data/user/0/...`) as `audio_path`
- [x] Staged audio files are deleted after successful upload
- [x] All existing unit tests pass

## Files to Change

| File | Change |
|------|--------|
| `app/lib/features/daily/recorder/services/transcription/streaming_audio_recorder.dart` | Move completed WAV from temp → `{appDocDir}/parachute/pending-audio/` before returning path |
| `app/lib/features/daily/journal/screens/journal_screen.dart` | Pass staged path (not temp path) to `api.uploadAudio()` and to `PendingEntryQueue` |
| `app/lib/features/daily/journal/services/pending_entry_queue.dart` | In `flush()`, if item `audioPath` is a local path: upload audio first; use server URL in `createEntry()`; delete local file |
| `app/lib/features/daily/journal/providers/journal_providers.dart` | (Part C) Listen to health provider; flush on reconnect |

## Technical Notes

- "Is a local path" check: `audioPath.startsWith('/')` is sufficient on Android/iOS/macOS
- `DailyApiService.uploadAudio()` already returns `null` on failure — no API change needed
- The staged audio directory `{appDocDir}/parachute/pending-audio/` should be created on first use
- On a successful flush, delete the staged file: `File(audioPath).deleteSync()`
- `_isFlushing` guard already in `PendingEntryQueue` — audio upload step must happen inside this guard to prevent double-upload
- Part C uses `ref.listen` on `periodicServerHealthProvider`; only trigger flush on `ServerHealthStatus.healthy` (not on every check)
