# Flutter App: Server-Side Transcription Integration

**Status:** Brainstorm
**Priority:** P1
**Labels:** app, daily
**Issue:** #262

---

## What We're Building

Wire the Flutter app to use the new server-side transcription pipeline (`POST /api/daily/entries/voice`) instead of always transcribing locally. When connected to a Parachute Computer server with transcription available, the app uploads audio and lets the server handle Parakeet transcription + LLM cleanup. Local transcription (existing `PostHocTranscriptionProvider`) remains as the offline fallback.

This is the app-side companion to the server work in #260 / PR #261.

## Why This Approach

The server has better hardware (Metal GPU via parakeet-mlx) and does LLM post-processing that the app can't. The user doesn't need immediate text — they just want to capture a voice note and move on. The AudioPen model: record → upload → done. Text appears when you next look at the journal.

Keeping local transcription as a fallback means the app works fully offline. A settings toggle lets power users choose their preferred mode.

## Key Decisions

1. **Default to server when connected.** Configurable in settings with three modes: `auto` (default — server when connected, local when offline), `server` (server only, fail if disconnected), `local` (always transcribe on-device). Auto is the right default for most users.

2. **No immediate text needed.** After recording, the entry appears in the journal list with a "processing" indicator. Text fills in asynchronously. This simplifies the app flow — no need for fast local preview followed by server overwrite.

3. **Light polling for in-flight entries.** When the journal screen has entries in `processing` or `transcribed` status, poll `GET /api/daily/entries/{id}` every ~5 seconds until they resolve. No general-purpose push infrastructure needed now — that's a separate future investment.

4. **Server capability check via health/modules endpoint.** Add `transcription_available: true/false` to the server's health or modules response. The app checks this to decide whether to offer the server path. No new endpoint required.

5. **Handle the `transcribed` intermediate state.** PR #259 taught the app about `processing`, `complete`, and `failed`. The server pipeline adds `transcribed` (raw Parakeet output, cleanup still running). Show raw text with a subtle "cleaning up..." indicator. Good enough — the raw text is readable.

6. **Existing local transcription code stays.** `PostHocTranscriptionProvider`, `PostHocTranscriptionService`, `TranscriptionProgressTracker` — all remain intact. They're activated when mode is `local` or when `auto` mode can't reach the server.

## Scope

### In Scope

- **Settings UI** — Transcription mode toggle (auto / server / local)
- **Recording flow branching** — After recording stops, check mode + connectivity → upload to server OR queue local transcription
- **Server upload** — `POST /api/daily/entries/voice` with audio file, date, duration
- **Server capability discovery** — Check `transcription_available` from health/modules response
- **Entry status polling** — Poll in-flight entries on journal screen until resolved
- **UI for `transcribed` state** — Show raw text with cleanup indicator
- **Error handling** — Server upload failure → fall back to local in auto mode, show error in server mode
- **Server endpoint for capability** — Add `transcription_available` field to health or modules response

### Out of Scope

- General server→app push notification channel (future infrastructure)
- "Show original" toggle for raw vs cleaned text (nice-to-have, later)
- Changes to Chat voice input (remains local streaming transcription)
- Server-side changes beyond the capability flag (transcription pipeline already built)

## Open Questions

1. **Which health endpoint gets the capability flag?** Options: `GET /api/health?detailed=true` (already used by app), or `GET /api/modules` (has module-level info). Leaning toward health since the app already calls it on connect.

2. **Polling frequency and timeout** — 5-second interval feels right. Should we cap polling at, say, 5 minutes and then show a "taking longer than expected" state? Transcription + cleanup should complete in under a minute for most recordings.

3. **Audio format for upload** — The app currently records to m4a (iOS/macOS) or wav (Android). The server accepts both via `ALLOWED_AUDIO_EXTENSIONS`. Should the app convert to a specific format before upload, or just send whatever the recorder produces?
