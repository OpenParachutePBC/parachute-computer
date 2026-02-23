---
status: complete
priority: p2
issue_id: "208"
tags: [code-review, python, quality, chat]
dependencies: []
---

# AUDIO_TYPES set defined twice as local variable in discord_bot.py

## Problem Statement

The constant `AUDIO_TYPES = {"audio/ogg", "audio/mpeg", "audio/wav", "audio/webm", "audio/mp4"}` is defined twice as a local variable inside two different methods in `discord_bot.py`: once inside the `on_message` closure (line 108) to route attachments, and again inside `on_voice_message` (line 274) to find the attachment to process. Both definitions are byte-for-byte identical. When the accepted audio formats change (e.g., adding `audio/flac`), the developer must update two independent locations or risk a mismatch where routing succeeds but processing fails.

## Findings

- `discord_bot.py:108` — first definition, inside `on_message` event handler closure
- `discord_bot.py:274` — second definition, inside `on_voice_message`
- The inner `if not audio: return` guard at line 280 is unreachable via the `on_message` routing path because routing only calls `on_voice_message` after a set-member check on the same constant
- python-reviewer confidence: 85; code-simplicity confidence: 90; pattern-recognition confidence: 84

## Proposed Solutions

### Option 1: Move to module-level constant (Recommended)
Define `AUDIO_TYPES` once at the top of `discord_bot.py` as a module-level constant (after imports). Remove both inline definitions.

```python
AUDIO_TYPES: frozenset[str] = frozenset({"audio/ogg", "audio/mpeg", "audio/wav", "audio/webm", "audio/mp4"})
```

Use `frozenset` to signal immutability.

**Pros:** Single source of truth, no duplication, correct semantics.
**Effort:** Small
**Risk:** None

### Option 2: Move to base.py
Define in `BotConnector` base class so all connectors share the constant.

**Pros:** Cross-platform consistency (Matrix uses the same types).
**Cons:** Base class may not be the right home for platform-specific MIME types.
**Effort:** Small
**Risk:** Low

## Recommended Action

## Technical Details

**Affected files:**
- `computer/parachute/connectors/discord_bot.py:108`
- `computer/parachute/connectors/discord_bot.py:274`

## Acceptance Criteria

- [ ] `AUDIO_TYPES` defined exactly once (module-level or base class)
- [ ] Both usage sites reference the shared constant
- [ ] Inner `if not audio: return` guard removed (dead code) or kept with a comment explaining the defensive fallback

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code
**Actions:**
- Found during PR #117 review by python-reviewer (85), code-simplicity (90), pattern-recognition (84)

## Resources

- **PR:** #117
- **Issue:** #88
