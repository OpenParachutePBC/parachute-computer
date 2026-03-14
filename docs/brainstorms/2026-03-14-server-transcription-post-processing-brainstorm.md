---
date: 2026-03-14
topic: server-transcription-post-processing
status: Brainstorm
priority: P1
**Issue:** #260
---

# Server-Side Transcription & LLM Post-Processing for Daily

## What We're Building

A server-side voice note processing pipeline for Parachute Daily. Audio recorded on the app gets uploaded to Parachute Computer, where it's transcribed with Parakeet V3 and then cleaned up by an LLM post-processing Caller. The result is a polished journal entry that reads like it was typed — filler words removed, proper punctuation, paragraph breaks — while preserving the speaker's voice and meaning.

This builds directly on the Tier 1 work from issue #258 (local post-hoc transcription) and shifts the heavy lifting to the server. It's the foundation for the full Parachute Daily hosted experience.

## Context

- Issue #258 shipped Tier 1: quiet recording UI + local post-hoc Parakeet transcription for Daily
- The graph database is now the source of truth for entries (not file sync), which simplifies the server-side story
- Daily has moved away from live transcription preview during recording — voice notes are recorded, then processed
- Reference product: AudioPen.ai — record voice note, get polished text back
- The Caller/agent infrastructure (issue #219, #258) already exists for running post-processing agents on journal entries

## Why This Approach

**Async Upload + Auto-triggered Caller** — transcription is infrastructure, post-processing is a Caller.

The server pipeline has two cleanly separated steps:

1. **Transcription (infrastructure):** Parakeet V3 on the server, processing the full audio in one pass. No chunking constraints that plague mobile devices. This is deterministic audio processing — it doesn't need agent flexibility.

2. **LLM Post-processing (Caller):** A built-in cleanup Caller that takes the raw transcription and produces polished text. Light-to-medium cleanup: remove filler words ("um", "uh"), fix grammar, add punctuation, create paragraph breaks, very light restructuring. Preserve the speaker's voice.

Why the Caller architecture for post-processing (not a simple API call):
- Users can customize their cleanup Caller or create their own
- Natural path to chaining Callers (cleanup → task extraction → etc.)
- The Caller infrastructure already exists (scheduling, sandboxed execution, graph integration)
- Sets the stage for the extensible post-processing pipeline

Alternatives considered:
- **Synchronous pipeline** (upload → process → return): Long recordings would hit request timeouts. Doesn't set up async architecture.
- **Caller does everything** (including transcription): Over-abstracts transcription. Mixing Parakeet native binary into sandboxed Caller containers adds unnecessary complexity. Transcription is infrastructure, not agent work.

## Key Decisions

### Transcription Model: Parakeet V3 on Server
- Same model the app uses locally, proven quality
- Full audio one-pass processing (no chunking constraints)
- No external API dependencies, no per-minute costs
- Audio stays on the user's server — privacy preserved
- Parachute Computer runs on decent hardware (Mac Mini, similar) — can handle it

### LLM Cleanup Level: Light-to-Medium
- Remove filler words, fix grammar, add punctuation
- Create paragraph breaks and line breaks
- Very light restructuring for readability
- Preserve the speaker's voice and meaning — don't rewrite, clean up
- Heavier transformations (summarization, task extraction) are future Callers, not the default

### Post-Processing via Caller Architecture
- Built-in "cleanup" Caller ships as default — great out of the box
- Extensible: users can create custom post-processing Callers later
- Supports chaining: cleanup Caller → task extraction Caller → etc.
- Uses existing Caller infrastructure (scheduling, sandboxing, graph integration)

### App-Side Flow
1. User stops recording
2. App creates entry stub in local SQLite: link to audio, status "needs upload"
3. Entry appears immediately in journal list (processing state)
4. App uploads audio to `POST /api/daily/entries/voice` with metadata
5. Server returns entry ID, status "processing"
6. Server transcribes → triggers cleanup Caller → entry updated in graph
7. App reflects polished entry on next sync/poll

### Two Tiers (Business Model)
- **Free tier:** Local on-device processing (existing Tier 1 from #258)
- **Paid/hosted tier:** Server-side transcription + LLM cleanup, potential voice note backups
- Building server-side now for the self-hosted Parachute Computer experience
- Hosted paid version comes later, may introduce API-based transcription options

## Open Questions

1. **Parakeet V3 server setup:** How to run Parakeet on the server? Python bindings via sherpa-onnx? Model download/management? Memory requirements for long recordings?
2. **Audio upload format:** WAV at 16kHz mono is ~1.9MB/min. Compress to Opus before upload? Or keep it simple with WAV for v1?
3. **Cleanup Caller prompt:** What's the exact default prompt? How much context does it get (just the transcription, or also recent journal entries for continuity)?
4. **Auto-trigger mechanism:** How does transcription completion trigger the cleanup Caller? Event hook? Direct invocation from the transcription task?
5. **Entry versioning:** Does the cleanup Caller overwrite the raw transcription, or does the entry keep both (raw + polished)? Keeping both enables "show original."
6. **Status polling vs. push:** How does the app know when processing is complete? Polling endpoint? Server-sent events? Check on next API sync?
7. **Error handling:** What happens if transcription succeeds but the Caller fails? Show raw transcription as fallback?
8. **Caller identity:** Which LLM powers the default cleanup Caller? Haiku for speed/cost? Sonnet for quality? Configurable?

## Next Steps

→ File GitHub issue with this design
→ Plan implementation, likely in phases:
  - Phase 1: Server-side Parakeet transcription endpoint (audio in, text out)
  - Phase 2: Cleanup Caller integration (auto-triggered post-processing)
  - Phase 3: App integration (upload flow, processing states, polished entry display)
→ Defer hosted/paid tier specifics to a separate brainstorm after v1 ships
