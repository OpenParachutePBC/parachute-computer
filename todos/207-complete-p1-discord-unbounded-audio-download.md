---
status: complete
priority: p1
issue_id: "207"
tags: [code-review, security, performance, python, chat]
dependencies: []
---

# Discord audio download has no size limit before read()

## Problem Statement

In `discord_bot.py:on_voice_message`, `audio.read()` is called without first checking the attachment's byte size. Discord attachments carry a `size` attribute (populated from metadata, zero network cost) but it is never consulted. A Discord Nitro user (25 MB attachment limit) or a server-configured limit can send audio files of up to 25 MB; the server downloads the full file into memory on every voice message. With no per-user rate limit and no byte cap, a single chat room can generate substantial memory pressure.

This is P1 because the upload-to-memory pipe is fully open: any authenticated Discord user with audio attachment capability can trigger an unbounded in-memory download on the server.

## Findings

- `discord_bot.py:293` — `audio_bytes = await audio.read()` — no size guard before this call
- `discord_bot.py:274-280` — `AUDIO_TYPES` check and `if not audio: return` happen first, but neither checks size
- Discord free tier: 8 MB attachment limit; Nitro: 25 MB; server-boosted: up to 100 MB
- `attachment.size` is available from Discord metadata before any download (no network call)
- No `MAX_AUDIO_BYTES` constant exists in the codebase
- security-sentinel confidence: 92; performance-oracle confidence: 90

## Proposed Solutions

### Option 1: Add size guard before read() (Recommended)
Define a module-level `MAX_AUDIO_BYTES = 10 * 1024 * 1024` (10 MB). Before calling `audio.read()`, check `if audio.size > MAX_AUDIO_BYTES`. Return a user-visible error message if exceeded.

**Pros:** Zero network cost for the check (metadata only), clear user feedback, prevents memory spike.
**Cons:** None.
**Effort:** Small
**Risk:** None — straightforward guard.

### Option 2: Stream audio in chunks with a cap
Instead of `audio.read()`, stream the attachment URL with `httpx.AsyncClient` and abort after N bytes.

**Pros:** Handles edge cases where `attachment.size` metadata is incorrect.
**Cons:** More complex, requires HTTP client; overkill given Discord metadata reliability.
**Effort:** Medium
**Risk:** Low

### Option 3: Delegate to a separate download service
Move audio fetching out of the connector into a server-side service with proper limits, queuing, and backpressure.

**Pros:** Best long-term architecture.
**Cons:** Significant scope expansion; overkill for an MVP connector.
**Effort:** Large
**Risk:** Medium (architecture change)

## Recommended Action

## Technical Details

**Affected files:**
- `computer/parachute/connectors/discord_bot.py:293`
- `computer/parachute/connectors/discord_bot.py:271` (on_voice_message start)

**Related:** Matrix connector's audio download path should also be checked (see todo #212).

## Acceptance Criteria

- [ ] `MAX_AUDIO_BYTES` constant defined (e.g., 10 MB or configurable)
- [ ] `audio.size > MAX_AUDIO_BYTES` check added before `audio.read()`
- [ ] User receives a clear error message if their audio file exceeds the limit
- [ ] Existing voice message tests continue to pass
- [ ] New test covers the over-limit case

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code
**Actions:**
- Found during PR #117 review by security-sentinel (confidence 92) and performance-oracle (confidence 90)
- Issue: `audio.read()` at `discord_bot.py:293` with no prior size guard

## Resources

- **PR:** #117
- **Issue:** #88 (bot connector cross-platform consistency)
