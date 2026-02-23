---
status: complete
priority: p2
issue_id: "214"
tags: [code-review, security, python, chat]
dependencies: []
---

# Discord attachment content_type is client-controlled and spoofable

## Problem Statement

`discord_bot.py:on_message` uses `attachment.content_type` to decide whether to route a message to `on_voice_message`. The `content_type` field is set by the Discord client and is not verified by the Discord gateway — a user can send a file with a non-audio extension but set its MIME type to `audio/ogg` to trigger the transcription path. Conversely, a legitimate audio file may have a wrong or missing MIME type and be silently ignored.

This matters because the transcription path downloads the file, calls an external service, and routes the result through the AI pipeline. Triggering this path with arbitrary binary content could cause unexpected behavior in the transcription service.

## Findings

- `discord_bot.py:108` — `if any(a.content_type in AUDIO_TYPES for a in message.attachments)` — sole gate is spoofable MIME type
- Discord API docs note that `content_type` is provided by the uploader, not verified by Discord
- security-sentinel confidence: 85

## Proposed Solutions

### Option 1: Also check file extension as a secondary signal (Recommended)
Add an extension allow-list check alongside the MIME check:

```python
AUDIO_EXTENSIONS = {".ogg", ".mp3", ".wav", ".webm", ".mp4", ".m4a", ".oga"}
def _is_audio_attachment(a):
    ext = Path(a.filename).suffix.lower()
    return a.content_type in AUDIO_TYPES and ext in AUDIO_EXTENSIONS
```

Require **both** MIME type and extension to match. This raises the bar significantly — an attacker would need to name their file with an audio extension AND claim an audio MIME type.

**Pros:** Defense-in-depth, straightforward, user-transparent.
**Effort:** Small
**Risk:** None — only restricts further

### Option 2: Accept any extension, rely on transcription service rejection
Let the transcription service return an error for non-audio content. Handle the error gracefully.

**Pros:** Simpler gate logic.
**Cons:** File is downloaded and sent to external service before the error fires; costs bandwidth and money.
**Effort:** Tiny
**Risk:** Medium (cost + potential prompt manipulation via error messages)

### Option 3: Magic-byte check (read first N bytes)
Check the file's magic bytes before routing.

**Pros:** Strongest content verification.
**Cons:** Requires partial download before deciding; complex for streaming formats.
**Effort:** Large

## Recommended Action

## Technical Details

**Affected files:**
- `computer/parachute/connectors/discord_bot.py:108`

## Acceptance Criteria

- [ ] MIME type check supplemented with file extension check
- [ ] Non-audio extensions are rejected even with a valid MIME type
- [ ] Valid audio files with standard extensions continue to work

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code
**Actions:**
- Found during PR #117 review by security-sentinel (confidence 85)

## Resources

- **PR:** #117
- **Issue:** #88
