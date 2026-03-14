---
date: 2026-03-14
topic: daily-transcription-rethink
---

# Daily Transcription Rethink

## What We're Building

Redesign how voice recording and transcription works in Parachute Daily, shifting from live streaming transcription (shows words as you speak) to a quieter recording experience with higher-quality post-hoc processing. The server tier adds LLM cleanup so voice journals read like typed entries.

## Context

From Aaron's March 13 journal entry: live transcription during voice journaling can be distracting — the typos pull attention away from thinking. Parakeet V3 produces better results when processing audio as a whole rather than in rolling 3-second windows. The current 30-second chunked processing (Android) introduces boundary artifacts: split words, lost punctuation, occasional hallucinations.

Reference implementation: [Handy](https://github.com/cjpais/handy) uses Parakeet V3 with **zero chunking** — entire audio processed in one pass, with Silero VAD filtering silence during capture to keep the buffer manageable.

## Why This Approach

**Current architecture:** Records audio → re-transcribes every 3s via Local Agreement algorithm → shows confirmed/interim text live → finalizes on silence. Complex pipeline (StreamingAudioRecorder → SimpleNoiseFilter → SmartChunker → TranscriptionQueue → LocalAgreementState → SegmentPersistence) with significant boundary quality issues on long recordings.

**New architecture:** Records audio → VAD filters silence in real-time → on stop, one-pass transcription → optional server enhancement with LLM cleanup. Simpler pipeline, better output quality, calmer recording experience.

Explored alternatives:
- **Keep live transcription:** Cognitive science research on dual-task interference suggests reading text while speaking competes for attentional resources. AudioPen (closest competitor) shows nothing during recording and is successful.
- **Always server:** Would break offline-first promise and add latency for short recordings.
- **Always local:** Can't do LLM cleanup, limited by device memory for very long recordings.

## Key Decisions

### Recording UI (Daily only — Chat stays as-is for now)
- Remove live transcription display during recording
- Show clean recording screen: waveform/VAD indicator, timer, stop button
- Spacious, calm — supports thinking mode

### Transcription Pipeline: Two Tiers

**v1 ships with Tier 1 only. Tier 2 is the upgrade path that comes with Parachute sync.**

- **Tier 1 — Local (v1 launch, always available):**
  - VAD filtering during capture (Silero-style, strip silence in real-time)
  - On stop: post-hoc Parakeet transcription in background isolate
  - iOS/macOS: one-pass, no chunking (CoreML + Neural Engine)
  - Android: VAD-boundary chunking — split at natural silence pauses, not fixed intervals. Produces ~8-12 large chunks for a long recording instead of 240 fixed 30s chunks. Eliminates mid-sentence boundary artifacts.
  - Background processing with resume: persists progress so if user navigates away or app closes, transcription picks up where it left off
  - Progress indicator: "Processing your entry..." with chunk progress for long recordings
  - Result: good quality, works fully offline

- **Tier 2 — Server-enhanced (future, when connected + opted in):**
  - Audio uploads in background after local transcription completes
  - Server processes with larger model, no chunking constraints
  - LLM cleanup pass: grammar, filler words, formatting — voice notes read like typed entries
  - Pushes improved version back, replaces local transcription
  - User sees subtle "enhanced" indicator
  - This is the upgrade path that comes with Parachute sync

### Scope
- **In scope:** Daily voice recording UI + transcription pipeline
- **Out of scope for now:** Chat voice input (stays as-is with live transcription)
- **Rationale:** Daily is the product shipping to users. Chat works fine, different UX needs (verify before send), and server-side processing for Chat is a separate conversation.

## Open Questions (v1)

1. **VAD implementation:** Port Silero VAD into Flutter/Dart, or use a native bridge? Handy does it in Rust. Need to evaluate options for iOS and Android.
2. **Android VAD-boundary chunking:** Need to benchmark larger chunks on representative devices. How does Sherpa-ONNX handle 5-min and 10-min windows? OOM risk?
3. **Progress UX for long recordings:** Progress bar with chunk count? Percentage? Simple "Processing... this may take a minute"?
4. **Crash recovery / resume:** Adapt existing SegmentPersistence to track which chunks have been transcribed. If app closes mid-processing, resume from last completed chunk on next open.
5. **Migration path:** The current streaming pipeline (SmartChunker, TranscriptionQueue, LocalAgreement, etc.) can be removed for Daily but must remain available for Chat. Clean separation needed.

## Open Questions (Tier 2 / future)

1. **Server transcription model:** Whisper Large V3 Turbo? Parakeet on server? Something else?
2. **LLM cleanup prompt:** Default prompt design. Handy lets users pick; we want a sensible default with customization later.
3. **Upload strategy:** WAV at 16kHz mono is ~1.9MB/min (30 min = ~57MB). Compress to Opus first?
4. **Entry versioning:** When server version arrives, replace silently? Show indicator? Keep local version?

## Next Steps

→ File GitHub issue with the v1 design
→ Plan implementation in two phases:
  - Phase 1: New recording UI + VAD filtering (remove live transcription display, add waveform/timer, integrate VAD during capture)
  - Phase 2: Post-hoc local transcription (replace streaming pipeline with one-pass/VAD-boundary chunking, background processing with resume)
→ Tier 2 (server enhancement) becomes its own issue after v1 ships
