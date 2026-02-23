---
status: complete
priority: p3
issue_id: "216"
tags: [code-review, python, quality, chat]
dependencies: []
---

# transcribe_audio vs transcribe server attribute naming divergence

## Problem Statement

Discord and Matrix look up `self.server.transcribe_audio`; Telegram looks up `self.server.transcribe`. If the server wires up only one of these names, two connectors silently fall back to "transcription unavailable" while the third works. This PR aligned Discord with Matrix (`transcribe_audio`) but widened the gap with Telegram.

```python
# discord_bot.py:287, matrix_bot.py:534
transcribe = getattr(self.server, "transcribe_audio", None)

# telegram.py:502
transcriber = getattr(self.server, "transcribe", None)
```

The server currently exposes neither (both return `None`), but when transcription is implemented, one set of connectors will be broken by default.

## Findings

- `discord_bot.py:287` — `getattr(self.server, "transcribe_audio", None)`
- `matrix_bot.py:534` — `getattr(self.server, "transcribe_audio", None)`
- `telegram.py:502` — `getattr(self.server, "transcribe", None)`
- pattern-recognition-specialist confidence: 85

## Proposed Solutions

### Option 1: Standardize on transcribe_audio across all connectors
Change `telegram.py:502` to use `transcribe_audio` to match Discord and Matrix.

**Pros:** Single name, consistent with the attribute defined in todo #219 for the REST API.
**Effort:** Tiny
**Risk:** None (all return None currently)

### Option 2: Standardize on transcribe
Change Discord and Matrix to use `transcribe` to match the existing Telegram convention.

**Pros:** Shorter name.
**Cons:** Goes against this PR's direction; undoes an alignment.
**Effort:** Tiny

## Recommended Action

## Technical Details

**Affected files:**
- `computer/parachute/connectors/telegram.py:502`
- (or discord_bot.py:287 and matrix_bot.py:534 for Option 2)

## Acceptance Criteria

- [ ] All three connectors use the same server attribute name for transcription
- [ ] The chosen name matches what the server will expose when transcription is implemented

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code
**Actions:**
- Found during PR #117 review by pattern-recognition-specialist (confidence 85)

## Resources

- **PR:** #117
- **Issue:** #88
