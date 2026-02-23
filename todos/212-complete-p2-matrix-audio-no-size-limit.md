---
status: complete
priority: p2
issue_id: "212"
tags: [code-review, security, python, chat]
dependencies: []
---

# Matrix audio download has no size limit before read()

## Problem Statement

The Matrix connector's `on_voice_message` downloads audio content from the Matrix homeserver without checking the file size first. While Matrix media is accessed via the homeserver (not directly from clients), there is no client-side byte cap on the download. This is the same class of issue as the Discord unbounded audio download (todo #207), applied to the Matrix connector.

## Findings

- `matrix_bot.py:530-536` — audio content fetched via Matrix client API, no size check
- Matrix servers may impose their own limits, but there is no client-side enforcement in the connector
- security-sentinel confidence: 83

## Proposed Solutions

### Option 1: Add size guard using Matrix event content info (Recommended)
Matrix audio events include `content.info.size` in their event body. Check this against `MAX_AUDIO_BYTES` before downloading.

```python
audio_info = event_content.get("info", {})
audio_size = audio_info.get("size", 0)
if audio_size > MAX_AUDIO_BYTES:
    await self._send_message(room_id, f"Audio file too large ({audio_size // 1024 // 1024} MB). Limit is {MAX_AUDIO_BYTES // 1024 // 1024} MB.")
    return
```

**Pros:** Uses existing metadata, consistent with Discord fix.
**Effort:** Small
**Risk:** Low — `info.size` may be missing for some clients, so treat 0 as unknown (allow but log).

### Option 2: Share MAX_AUDIO_BYTES constant between connectors
Define in `base.py` or a shared constants module; import in both Discord and Matrix connectors.

**Pros:** Single definition, cross-platform consistency.
**Effort:** Small additional step on top of Option 1

## Recommended Action

## Technical Details

**Affected files:**
- `computer/parachute/connectors/matrix_bot.py:530`

**Related:** Discord version of this issue is todo #207 (P1 due to larger attack surface).

## Acceptance Criteria

- [ ] Matrix `on_voice_message` checks audio size before download
- [ ] User receives error message if file exceeds limit
- [ ] `MAX_AUDIO_BYTES` constant shared with Discord connector

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code
**Actions:**
- Found during PR #117 review by security-sentinel (confidence 83)

## Resources

- **PR:** #117
- **Issue:** #88
