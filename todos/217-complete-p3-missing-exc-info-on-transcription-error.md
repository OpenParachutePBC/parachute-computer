---
status: complete
priority: p3
issue_id: "217"
tags: [code-review, python, quality, chat]
dependencies: []
---

# Missing exc_info=True on transcription error log in discord_bot.py

## Problem Statement

When transcription fails with an exception in `on_voice_message`, the error is logged with `logger.error(...)` but without `exc_info=True`. The stack trace is lost, making it harder to debug transcription failures in production.

## Findings

- `discord_bot.py:300` (approximately) — `logger.error(f"Transcription failed: {e}")` — no `exc_info`
- python-reviewer confidence: 75

## Proposed Solutions

### Option 1: Add exc_info=True
```python
logger.error("Transcription failed for %s: %s", audio.filename, e, exc_info=True)
```

**Effort:** Tiny

## Recommended Action

## Technical Details

**Affected files:**
- `computer/parachute/connectors/discord_bot.py` (transcription error handler in on_voice_message)

## Acceptance Criteria

- [ ] Transcription exception logger call includes `exc_info=True`

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code

## Resources

- **PR:** #117
