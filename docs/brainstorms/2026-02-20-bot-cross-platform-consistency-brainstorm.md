---
title: Bot Connector Cross-Platform Consistency
status: brainstorm
priority: P2
module: computer
tags: [bot-framework, bug, consistency]
issue: 88
---

# Bot Connector Cross-Platform Consistency

## What We're Building

Fix inconsistencies across the three bot connectors (Telegram, Discord, Matrix) so they behave uniformly. The audit found divergent behavior in error handling, streaming, voice support, ack emoji lifecycle, and event processing.

### The Problems

**1. Error event handling asymmetry**
- Telegram handles `typed_error` events but Discord doesn't set `error_occurred` flag
- Matrix connector doesn't distinguish error types at all
- Warning events (`warning` type from MCP/attachments) are silently dropped by all connectors
- Users on Discord/Matrix see silence when errors occur; Telegram users see `⚠️ Error: ...`

**2. Voice message support gaps**
- Telegram: Full voice support (download → transcribe → process)
- Matrix: Full voice support (download → transcribe → process)
- Discord: No voice support at all — audio attachments silently ignored

**3. Ack emoji inconsistency**
- Telegram: Sends reaction on receive, removes after response sent
- Discord: Config field exists but ack emoji is never sent
- Matrix: Sends reaction on receive, never removes it

**4. Streaming behavior**
- Telegram: Progressive message edits (great UX, up to 25 edits)
- Discord: Collects full response, sends at once
- Matrix: Collects full response, sends at once

**5. Group history approach**
- Telegram: Ring buffer (fast, in-memory)
- Discord: Fetches via API call each time (slower, network-dependent)
- Matrix: Ring buffer (fast, in-memory)

## Why This Approach

Fix the bugs and inconsistencies incrementally — each is a small, focused change. Don't try to make all platforms identical (streaming edits are platform-specific), but ensure the baseline behavior (errors shown, voice works, ack lifecycle consistent) is uniform.

### Priority Order

1. **Error/warning event handling** — Users getting silence on errors is a bug. Add `typed_error` and `warning` handling to Discord and Matrix.
2. **Discord voice support** — Use `message.attachments` to detect audio, download, transcribe. Pattern already exists in Telegram/Matrix.
3. **Ack emoji lifecycle** — Either remove after response on all platforms, or don't remove on any. Pick one and be consistent.
4. **Discord group history** — Switch from API fetch to ring buffer. Already works in Telegram/Matrix.
5. **Streaming for Discord/Matrix** — Lower priority, nice-to-have. Discord supports message editing; Matrix supports message replacement events.

### Scope

- Changes to `discord_bot.py`, `matrix_bot.py`, `telegram.py`
- No base class changes
- No API or Flutter changes

## Key Decisions

- **Fix errors first** — Silent failures are the worst UX
- **Don't force streaming everywhere** — It's a platform-specific optimization
- **Ack emoji: send on receive, remove after response** — Telegram's behavior is the gold standard

## Open Questions

- Should Discord streaming use webhook edits or regular message edits?
- Is Matrix message replacement (`m.replace` relation) worth the complexity for streaming?
