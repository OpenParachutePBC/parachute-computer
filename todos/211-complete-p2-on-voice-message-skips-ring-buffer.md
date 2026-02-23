---
status: complete
priority: p2
issue_id: "211"
tags: [code-review, python, quality, chat]
dependencies: []
---

# Discord on_voice_message skips group ring buffer recording

## Problem Statement

Discord's new `on_voice_message` transcribes audio to text and then calls `_route_to_chat` directly, bypassing `on_text_message`. This means the voice message transcript is never recorded to the `group_history` ring buffer. In a group channel, any subsequent text message from the same or another user will lack the voice turn in its `<group_context>`, breaking conversational continuity.

**Cross-platform comparison:**

| Platform | After transcription |
|---|---|
| Matrix | `await self.on_text_message(update, context)` — delegates back, buffer populated naturally |
| Discord | `await self._route_to_chat(session_id=..., message=text)` — skips buffer entirely |
| Telegram | Routes back through same text pipeline |

Discord and Matrix should behave the same here.

## Findings

- `discord_bot.py:335` — `_route_to_chat` called directly after transcription
- `matrix_bot.py:543` — delegates back to `on_text_message` (correct pattern)
- The `group_history` ring buffer is only populated in `on_text_message` (line 154)
- pattern-recognition-specialist confidence: 87; architecture-strategist confidence: 87

## Proposed Solutions

### Option 1: Record to ring buffer explicitly in on_voice_message (Recommended)
Before calling `_route_to_chat`, check `if chat_type == "group"` and call `self.group_history.record(user_id, display_name, text)` with the transcribed text. This keeps the voice handler self-contained.

**Pros:** Clear intent, no abstraction change needed, mirrors what `on_text_message` does.
**Effort:** Small
**Risk:** Low

### Option 2: Delegate to on_text_message after transcription (like Matrix)
Reconstruct a fake message object with `.content = text` and call `await self.on_text_message(fake_message, None)`.

**Pros:** Reuses pipeline uniformly (auth re-check, ack, buffer, chat).
**Cons:** Requires constructing a mock Discord Message object; could be fragile against Discord.py API changes.
**Effort:** Medium
**Risk:** Medium

### Option 3: Extract shared voice+text pipeline method
Create `_process_text(user_id, display_name, text, chat_type, session, ack_fn)` that both `on_text_message` and `on_voice_message` call. Handles buffer recording and chat routing in one place.

**Pros:** Best abstraction; aligns with Telegram's `_process_text_message` pattern.
**Cons:** Larger refactor scope.
**Effort:** Medium-Large

## Recommended Action

## Technical Details

**Affected files:**
- `computer/parachute/connectors/discord_bot.py:335` (missing record call)
- `computer/parachute/connectors/discord_bot.py:154` (where record happens in text path)

## Acceptance Criteria

- [ ] Voice messages in a Discord group channel are recorded to `group_history`
- [ ] Subsequent text messages in the same channel include the voice turn in `<group_context>`
- [ ] Tests verify voice message appears in ring buffer after `on_voice_message`

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code
**Actions:**
- Found during PR #117 review by pattern-recognition-specialist (87) and architecture-strategist (87)
- Matrix correctly delegates to `on_text_message`; Discord does not

## Resources

- **PR:** #117
- **Issue:** #88
