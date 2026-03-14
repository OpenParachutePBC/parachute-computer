---
title: "Daily transcription rethink — quiet recording UI + post-hoc processing"
type: feat
date: 2026-03-14
issue: 258
deepened: 2026-03-14
---

# Daily transcription rethink — quiet recording UI + post-hoc processing

Replace live streaming transcription in Daily with a calm recording screen and higher-quality post-hoc batch transcription. Chat is untouched.

## Enhancement Summary

**Deepened on:** 2026-03-14
**Sections enhanced:** 7
**Review agents used:** Architecture Strategist, Performance Oracle, Code Simplicity Reviewer, Security Sentinel, Pattern Recognition Specialist, Framework Docs Researcher

### Key Improvements
1. **Simplified scope** — Phase 2b (lifecycle edge cases) deferred entirely to a follow-up issue. v1 ships Phase 1 + Phase 2 core only.
2. **Fixed 60s chunking for v1** — VAD-boundary chunking adds complexity for marginal v1 gain. Use simple fixed 60s chunks on Android, upgrade to VAD-boundary in a future pass.
3. **Memory-safe architecture** — Explicit memory budget (200MB ceiling), streaming WAV reads, and fallback chunking strategy for 2-hour recordings.
4. **Server-side status validation** — Whitelist valid status transitions to prevent client spoofing.
5. **Orphaned entry cleanup** — 24-hour timeout for entries stuck in "processing" state.

### Scope Reduction (from Simplicity Review)
- ~~Phase 2b~~ → Deferred to follow-up issue. v1 handles the happy path; lifecycle edge cases (backgrounding, crash recovery, phone interrupts) are future work.
- ~~Feature flag~~ → Removed. We're committing to this direction; the old streaming code stays in the codebase for Chat, no flag needed.
- ~~VAD-boundary chunking~~ → Deferred. Fixed 60s chunks on Android is the v1 approach. VAD-boundary alignment is a quality enhancement for a future iteration.
- ~~TranscriptionProgressTracker~~ → Simplified to minimal JSON: `{entryId, audioPath, status}`. No chunk-level resume tracking for v1.

---

## Problem Statement

The current Daily voice recording pipeline shows live transcription as you speak — re-transcribing every 3 seconds via a Local Agreement algorithm. This has two problems:

1. **UX:** Live transcription is distracting during voice journaling. Typos and interim text pull attention away from thinking. Cognitive science research on dual-task interference confirms that reading/error-checking competes with speech production.

2. **Quality:** The 30-second fixed chunking on Android introduces boundary artifacts — split words, lost punctuation, occasional hallucinations. With ~240 chunk boundaries for a 2-hour recording, these add up. Parakeet V3 produces better results on larger audio segments.

## Proposed Solution

**Recording UI:** Remove `StreamingTranscriptionDisplay` and `StreamingRecordingOverlay`. Replace with a minimal recording screen: waveform visualization, wall-clock timer, stop button, cancel button. No text appears during recording.

**Transcription:** After recording stops, process the full audio file through `TranscriptionServiceAdapter.transcribeAudio()` in a background isolate. On iOS this is already one-pass. On Android, `SherpaOnnxService` already chunks internally — we increase the chunk window from 30s to fixed 60s to reduce boundary artifacts.

**Entry lifecycle:** Entry is created in "processing" state immediately after recording stops. User sees a placeholder in the entry list with a progress indicator. When transcription completes, the entry updates with the full text.

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Live transcription in Daily | Remove entirely | Distracting, lower quality than batch |
| Chat voice input | Untouched | Different UX needs (verify before send) |
| VAD during capture | Not used for v1 | Adds complexity; VAD filtering is future work (Silero upgrade) |
| iOS background processing | Pauses when backgrounded, resumes when foregrounded | No App Store risk, simple, acceptable for v1 |
| iOS crash recovery | Full restart on next app open | One-pass architecture, simple, acceptable for v1 |
| Android chunk window | Fixed 60s (up from 30s) | Reduces boundary artifacts ~4x. VAD-boundary alignment is future work |
| Audio retention | Keep audio file with entry, user deletes via entry delete | Enables re-processing, re-listening, future server enhancement |
| Short recordings (< 3s) | Discard with toast message | Prevents accidental taps from creating empty entries |
| Processing queue | Sequential, one at a time | Prevents memory pressure, simple |
| Timer display | Wall-clock time | Intuitive; speech-active time is a future enhancement |
| Failed transcription | Keep entry in "failed" state with retry button | Audio is precious — a 30-min recording with no UI path is effectively lost. Retry is ~10 lines of code |
| Feature flag | None | We're committing to this direction. Old streaming code stays for Chat |

### Research Insights: Key Design Decisions

**From Simplicity Review — scope reduction rationale:**
- The original plan had 10 files across 3 phases. The simplified plan has 8 files across 2 phases, with Phase 2b deferred entirely.
- Feature flags add testing surface area and code paths. Since Chat still uses the streaming pipeline (it's not being deleted), there's no rollback risk — just revert the commit.
- Retry-on-failure requires: retry button UI, re-triggering transcription service, progress reset, re-entry into queue. Delete-and-re-record is one line of code and a toast.

**From Architecture Review — orphaned entry concern:**
- If the app is killed during transcription and the user never re-opens the app (or uninstalls), entries stuck in "processing" state persist forever on the server.
- **Mitigation:** Add a server-side sweep: entries in "processing" state for >24 hours get set to "failed". This is a single cron job or startup check — low cost, high safety.

---

## Technical Approach

### Architecture

```
CURRENT (Daily voice recording):
  Record → LiveTranscriptionService → SmartChunker (30s) →
  TranscriptionQueue → LocalAgreement → Live UI display →
  On stop: finalize → create entry

NEW (Daily voice recording):
  Record → StreamingAudioRecorder (audio only, no transcription) →
  On stop: create entry (status=processing) →
  Background: TranscriptionServiceAdapter.transcribeAudio(wavPath) →
  On complete: update entry with text (status=complete)
```

### Research Insights: Architecture

**From Performance Review — memory budget:**
- A 2-hour 16kHz mono WAV is ~230MB on disk.
- `SherpaOnnxIsolate` loads the Parakeet model (~80-120MB) plus holds one chunk in memory.
- With 60s chunks, each chunk is ~1.9MB of audio data — very manageable.
- **Total isolate memory ceiling:** ~200MB (model + chunk buffer + overhead). This is safe on devices with ≥3GB RAM.
- **Risk:** iOS one-pass on a 2-hour file loads the entire WAV into memory. Need to verify `FluidAudio`/CoreML handles streaming reads, or cap one-pass at 30 minutes and fall back to chunking.

**From Performance Review — storage considerations:**
- 2-hour WAV at 16kHz mono = ~230MB.
- Check available disk space before recording starts. Warn if < 500MB free.
- Stage audio to `{appDocDir}/parachute/pending-audio/` (durable, not temp).
- Clean up audio after entry is confirmed saved (or after server upload in Tier 2).

**From Pattern Recognition — provider architecture:**
- The codebase pattern is: **providers orchestrate, services execute**. `PostHocTranscriptionService` should handle transcription only. The provider should handle entry creation, API calls, and state coordination.
- Use a typed progress class (sealed class / freezed union) instead of a raw map:
```dart
sealed class TranscriptionProgress {
  const TranscriptionProgress();
}
class TranscriptionIdle extends TranscriptionProgress { ... }
class TranscriptionInProgress extends TranscriptionProgress {
  final double progress; // 0.0 - 1.0
  final int chunksCompleted;
  final int totalChunks;
}
class TranscriptionComplete extends TranscriptionProgress {
  final String transcription;
}
class TranscriptionFailed extends TranscriptionProgress {
  final String error;
}
```

### Entry State Machine

```
┌──────────┐     ┌────────────┐     ┌──────────┐
│ recording │ ──→ │ processing │ ──→ │ complete │
└──────────┘     └────────────┘     └──────────┘
      │                │
      ↓                ↓
  ┌─────────┐    ┌────────┐
  │ discard │    │ failed │ → retry → processing
  └─────────┘    └────────┘
```

**Failure handling:**
- **Interruptions** (app killed, backgrounded) never reach "failed" — the `TranscriptionProgressTracker` detects the incomplete job on next launch and automatically restarts transcription.
- **Actual failures** (model OOM, corrupted audio) → entry stays in "failed" state with a retry button. Audio is preserved. User taps retry, which just calls the same `transcribe(entryId, audioPath)` again.
- **Why not delete-and-re-record?** A 30-minute recording with no UI path to it is effectively lost. The audio file exists at its path but the user can't find it. Retry is ~10 extra lines of code and protects the user's content.

---

### Implementation Phases

#### Phase 1: New recording UI + simplified recording service

**Goal:** Remove live transcription display, replace with calm recording screen. Recording still captures audio to WAV exactly as before.

**Files to modify:**

1. **`app/lib/features/daily/recorder/widgets/streaming_transcription_display.dart`**
   - Replace `StreamingRecordingOverlay` with new `DailyRecordingOverlay`:
     - `RecordingWaveform` — audio level visualization (use existing `vadActivityStream` for levels)
     - Wall-clock timer (reuse `StreamingRecordingHeader` timer logic)
     - Stop button (red circle, prominent)
     - Cancel/discard button (smaller, secondary)
   - Remove `StreamingTranscriptionDisplay` usage from Daily (keep widget available for Chat)

2. **`app/lib/features/daily/recorder/providers/streaming_transcription_provider.dart`**
   - Add `dailyRecordingOnlyProvider` — simplified provider that starts/stops `StreamingAudioRecorder` without the live transcription pipeline
   - Keep existing streaming providers intact (Chat still uses them)

3. **`app/lib/features/daily/journal/widgets/journal_input_bar.dart`**
   - In `_startRecording()`: use new `dailyRecordingOnlyProvider` instead of `streamingRecordingProvider`
   - In `_stopRecording()`: get audio file path, skip `getStreamingTranscript()`, trigger post-hoc processing (Phase 2)
   - Add cancel/discard handling: delete audio file, no entry created
   - Add minimum duration check: if < 3 seconds, discard with toast

4. **New widget: `app/lib/features/daily/recorder/widgets/recording_waveform.dart`**
   - Simple waveform visualization driven by audio level stream
   - Animated bars or smooth wave, using `BrandColors.forest`
   - Listens to audio amplitude from recorder (not VAD — just raw levels for visual feedback)

**Haptics:**
- `HapticFeedback.mediumImpact()` on recording start
- `HapticFeedback.heavyImpact()` on recording stop
- Light haptic on discard

#### Phase 1: Research Insights

**From Framework Docs — Flutter audio amplitude patterns:**
- Use `StreamBuilder` with the recorder's amplitude stream, not a periodic timer.
- For waveform visualization, sample at ~60fps but throttle repaints with `RepaintBoundary`.
- `CustomPainter` with a rolling buffer of amplitude values (last 50-100 samples) gives a clean waveform effect.

**From Framework Docs — audio session management:**
- Use the `audio_session` package to configure the audio category before recording starts.
- On iOS, set `.playAndRecord` category with `.defaultToSpeaker` option.
- This prevents audio ducking issues where the recording volume drops when other apps play audio.

---

#### Phase 2: Post-hoc batch transcription with background processing

**Goal:** After recording stops, transcribe the full audio file in background. Show progress.

**Files to modify:**

1. **`app/lib/features/daily/recorder/services/post_hoc_transcription_service.dart`** (NEW)
   - Thin service: accepts a WAV path, calls `TranscriptionServiceAdapter.transcribeAudio(wavPath)`, emits `TranscriptionProgress` via stream
   - Does NOT create entries or call APIs (that's the provider's job — per codebase patterns)
   - Receives progress callbacks from `SherpaOnnxIsolate` (already supports `onProgress`)
   - On completion: returns transcription text
   - On failure: throws, preserves audio

2. **`app/lib/features/daily/recorder/services/transcription_progress_tracker.dart`** (NEW)
   - Minimal JSON persistence: `{entryId, audioPath, status}`
   - Location: `{appDocDir}/parachute/transcription-jobs/`
   - On app startup: checks for incomplete jobs → restarts transcription
   - Cleans up completed job files after entry is confirmed saved
   - **Deliberately simple for v1:** No chunk-level tracking. If interrupted, restart from scratch.

3. **`app/lib/core/services/transcription/sherpa_onnx_service.dart`**
   - Increase `_chunkDurationSeconds` from 30 to 60 for Daily path
   - Add `transcribeAudioLargeChunks(wavPath, {chunkSeconds: 60})` method
   - Keep existing 30s chunking as default for Chat compatibility
   - **v1 keeps fixed-interval chunking.** VAD-boundary alignment is a future quality enhancement.

4. **`app/lib/features/daily/journal/widgets/journal_screen.dart`**
   - Entry list: show processing entries with progress indicator
   - Processing entry card: subtle shimmer or progress bar, "Transcribing..." label
   - Failed entry card: brief error message + "Retry" button. Tapping retry calls `transcribe(entryId, audioPath)` again via provider

5. **`app/lib/features/daily/journal/widgets/journal_input_bar.dart`**
   - After `_stopRecording()`:
     1. Stage audio to durable path (`{appDocDir}/parachute/pending-audio/`)
     2. Create entry via API with `status: processing`, `audio_path`, `metadata: {duration_seconds}`
     3. Start `PostHocTranscriptionService.transcribe(audioPath)` via provider
     4. Return to entry list (user sees the processing card)

6. **`app/lib/features/daily/recorder/providers/post_hoc_transcription_provider.dart`** (NEW)
   - Riverpod provider wrapping `PostHocTranscriptionService`
   - **Orchestrates the full lifecycle:** creates entry, starts transcription, updates entry on completion, deletes entry on failure
   - `StreamProvider<TranscriptionProgress>` for current job status
   - On app startup: checks `TranscriptionProgressTracker` for incomplete jobs, restarts them

7. **`computer/modules/daily/module.py`** (server-side)
- `POST /api/daily/entries` — accept optional `status` field (default: "complete" for backward compat)
   - `PATCH /api/daily/entries/{id}` — allow updating `content` and `status` (for transcription completion)
   - Add `status` column to the graph schema `Note` table if not present

#### Phase 2: Research Insights

**From Security Review — server-side status validation (CRITICAL):**
- The `status` field MUST be validated server-side. A client should not be able to set arbitrary status values.
- **Whitelist valid values:** `["processing", "complete", "failed"]`
- **Whitelist valid transitions:** `processing → complete`, `processing → failed`
- Reject any other status value or transition with 400.
- The `PATCH` endpoint must verify the entry belongs to the authenticated user (or session).

```python
# computer/modules/daily/module.py — status validation
VALID_STATUSES = {"processing", "complete", "failed"}
VALID_TRANSITIONS = {
    "processing": {"complete", "failed"},
    "failed": {"processing"},  # retry
}

def update_entry(entry_id, content=None, status=None):
    if status and status not in VALID_STATUSES:
        raise ValueError(f"Invalid status: {status}")
    if status:
        current = get_entry_status(entry_id)
        if status not in VALID_TRANSITIONS.get(current, set()):
            raise ValueError(f"Invalid transition: {current} → {status}")
```

**From Security Review — audio file privacy:**
- Audio files contain raw voice data — highly sensitive PII.
- Files at `{appDocDir}/parachute/pending-audio/` are app-sandboxed on both iOS and Android (only this app can access).
- When audio upload to server is added (Tier 2), the asset endpoint MUST require authentication. The current `serve_asset()` in `module.py` should be audited.
- Consider: auto-delete audio files after 30 days if the user hasn't explicitly opted to keep them.

**From Performance Review — memory-safe transcription:**
- 60s chunk at 16kHz mono = ~1.92MB of PCM data. Very safe.
- The model itself is the memory bottleneck (~80-120MB for Parakeet INT8).
- `SherpaOnnxIsolate` already loads the model once and reuses it across chunks — no per-chunk loading overhead.
- **Fallback for very long recordings:** If the audio file is >500MB (roughly 4+ hours), show a warning before processing. This is an edge case but worth a guard.

**From Architecture Review — service responsibility split:**
- `PostHocTranscriptionService` should be a pure transcription wrapper: audio path in, text out, progress stream.
- The provider (`post_hoc_transcription_provider`) handles: entry creation, tracking persistence, API updates, failure handling.
- This matches the existing codebase pattern where `SherpaOnnxService` is a pure transcription service and providers orchestrate the workflow around it.

**From Framework Docs — Riverpod background job pattern:**
```dart
// Provider that survives navigation (keepAlive)
@riverpod
class PostHocTranscription extends _$PostHocTranscription {
  @override
  TranscriptionProgress build() => const TranscriptionIdle();

  Future<void> transcribe(String entryId, String audioPath) async {
    state = TranscriptionInProgress(progress: 0, chunksCompleted: 0, totalChunks: 0);
    try {
      final service = ref.read(postHocTranscriptionServiceProvider);
      final text = await service.transcribe(
        audioPath,
        onProgress: (p) => state = TranscriptionInProgress(
          progress: p.progress,
          chunksCompleted: p.chunksCompleted,
          totalChunks: p.totalChunks,
        ),
      );
      // Provider handles API update
      await ref.read(dailyApiServiceProvider).updateEntry(entryId, content: text, status: 'complete');
      state = TranscriptionComplete(transcription: text);
    } catch (e) {
      state = TranscriptionFailed(error: e.toString());
      // Entry stays in "failed" state. Audio preserved. User can retry.
      await ref.read(dailyApiServiceProvider).updateEntry(entryId, status: 'failed');
    }
  }

  /// Retry is just calling transcribe again with the same entry + audio path
  Future<void> retry(String entryId, String audioPath) => transcribe(entryId, audioPath);
}
```

**From Framework Docs — AppLifecycleState observer pattern:**
```dart
// Use WidgetsBindingObserver mixin or Riverpod's AppLifecycleProvider
final appLifecycleProvider = Provider<AppLifecycleState>((ref) {
  final observer = _AppLifecycleObserver(ref);
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
  return observer.state;
});
```
- On iOS `paused`: transcription isolate may be suspended by the OS. On `resumed`: check if the isolate is still responsive. If not, restart from the tracker state.
- On Android: Dart isolates survive backgrounding. No special handling needed for v1.

---

#### Phase 2b: Lifecycle edge cases — DEFERRED

> **Moved to follow-up issue.** Phase 2b (app backgrounding, crash recovery, phone call interrupts, storage full, processing queue) is deferred. v1 ships with Phase 1 + Phase 2 core. If the app is killed during transcription, the tracker detects the incomplete job on next launch and restarts it. That's sufficient for beta.
>
> Edge cases to address in the follow-up:
> 1. App backgrounded during processing (iOS pause/resume, Android foreground service)
> 2. App killed during processing (chunk-level resume on Android)
> 3. Phone call interrupts recording (AudioSession interruption events)
> 4. Storage full during recording
> 5. Processing queue (multiple recordings queued)

---

## Migration & Compatibility

- **Chat unaffected:** All changes are scoped to `features/daily/`. Shared components in `core/services/` are only extended (new methods), not modified.
- **Existing entries:** No migration needed. Existing entries already have `content` and `audio_path`. New entries add `status` field; old entries without it default to `complete`.
- **Streaming pipeline preserved:** `LiveTranscriptionService`, `TranscriptionQueue`, `LocalAgreement` etc. remain in the codebase. Chat still uses them via `StreamingVoiceService`. We remove their usage from Daily's code path only.

### Research Insights: Migration

**From Architecture Review — dependency on #256 (offline timestamps):**
- Issue #256 (offline timestamps) also modifies `computer/modules/daily/module.py` — specifically `create_entry()`.
- These changes are additive and non-conflicting: #256 adds `created_at`/`date` from client metadata, this plan adds `status` field.
- **Recommendation:** Ship #256 first (it's simpler), then this plan builds on top. The `PATCH` endpoint is net-new and has no conflict.

**From Pattern Recognition — code cleanup opportunity:**
- After this ships and stabilizes, the Daily-specific references to `LiveTranscriptionService`, `SmartChunker`, `TranscriptionQueue`, and `LocalAgreementState` can be removed from the `daily/` feature directory.
- Keep them in `core/services/` for Chat. But remove any imports or usages from `daily/` files.

---

## Acceptance Criteria

### Functional
- [ ] Daily recording screen shows waveform + timer, no live text
- [ ] Cancel button discards recording (no entry created)
- [ ] Recordings < 3 seconds auto-discard with toast
- [ ] After stop: entry appears in list with "processing" state and progress indicator
- [ ] Transcription completes in background, entry updates with text
- [ ] User can navigate away during processing and return to find completed entry
- [ ] App restart detects incomplete transcription and restarts it
- [ ] Failed transcription shows entry in "failed" state with retry button, audio preserved
- [ ] Chat voice input is completely unaffected
- [ ] Server validates `status` field values and transitions

### Non-Functional
- [ ] Short recording (< 2 min): transcription completes in < 10 seconds
- [ ] Long recording (30 min): transcription completes with progress indication, no OOM
- [ ] 2-hour recording: transcription completes within memory budget (~200MB isolate ceiling)
- [ ] UI remains responsive during background transcription (isolate-based)
- [ ] Audio files staged to durable storage (not temp directory)
- [ ] Disk space check before recording starts (warn if < 500MB free)

---

## Files Summary

| File | Action | Phase | Purpose |
|------|--------|-------|---------|
| `daily/recorder/widgets/streaming_transcription_display.dart` | Modify | 1 | Replace overlay for Daily, keep widgets for Chat |
| `daily/recorder/widgets/recording_waveform.dart` | New | 1 | Waveform visualization widget |
| `daily/recorder/providers/streaming_transcription_provider.dart` | Modify | 1 | Add recording-only provider for Daily |
| `daily/journal/widgets/journal_input_bar.dart` | Modify | 1+2 | New recording flow, cancel, min duration, post-hoc trigger |
| `daily/recorder/services/post_hoc_transcription_service.dart` | New | 2 | Thin transcription wrapper (audio in, text out) |
| `daily/recorder/services/transcription_progress_tracker.dart` | New | 2 | Minimal JSON job persistence |
| `daily/recorder/providers/post_hoc_transcription_provider.dart` | New | 2 | Orchestrates lifecycle: entry creation, transcription, API updates |
| `daily/journal/widgets/journal_screen.dart` | Modify | 2 | Processing/failed entry cards |
| `core/services/transcription/sherpa_onnx_service.dart` | Modify | 2 | Add 60s chunk option for Daily |
| `computer/modules/daily/module.py` | Modify | 2 | Entry status field + validation in API |

## References

- Brainstorm: `docs/brainstorms/2026-03-14-daily-transcription-rethink-brainstorm.md`
- GitHub issue: #258
- Handy reference implementation: https://github.com/cjpais/handy
- Existing fallback pattern: `RecordingPostProcessingService` in `journal_input_bar.dart`
- Audio staging pattern: `docs/plans/2026-03-04-feat-daily-offline-audio-upload-queue-plan.md`
- Crash recovery learnings: `docs/issues/2026-02-18-mid-stream-reconnection-frozen.md`
- Offline timestamps plan (ships first): `docs/plans/2026-03-13-fix-daily-offline-timestamps-sync-ui-plan.md`
