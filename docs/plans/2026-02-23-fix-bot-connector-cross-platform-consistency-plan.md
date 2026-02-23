---
title: Bot Connector Cross-Platform Consistency
type: fix
date: 2026-02-23
issue: 88
---

# Bot Connector Cross-Platform Consistency

## Overview

Fix four targeted inconsistencies across the Telegram, Discord, and Matrix bot connectors so they behave uniformly at the baseline. Each fix is independent and incremental. Streaming parity (Discord/Matrix progressive edits) is excluded from scope — it's platform-specific and lower priority.

**Files changed:** `discord_bot.py`, `matrix_bot.py` only. No base class, API, or Flutter changes.

---

## Problem Statement

### Fix 1 — `error` event drops to silence on Discord and Matrix (Critical)

All three connectors iterate the same orchestrator event loop. When an `error` type event arrives with no accompanying text content:

| Connector | `error` event | `error_occurred` flag |
|---|---|---|
| Telegram | logged; `error_occurred = True` (line 592) | ✅ present |
| Discord | logged only (line 440–441) | ❌ absent |
| Matrix | logged only (line 814–815) | ❌ absent |

In Discord and Matrix, if a bare `error` event fires and `response_text` remains empty, the fallback "No response from agent." is sent to the user — which is misleading. The user sees a response but it's wrong. Telegram suppresses this fallback via the `error_occurred` guard at line 631.

Minor cosmetic inconsistency: Matrix uses `msg` as the local variable name in `typed_error`/`warning` handling (lines 819, 825) while Telegram and Discord use `message`. Functionally identical but visually inconsistent when reading across files.

### Fix 2 — Discord voice messages silently ignored (High)

| Connector | Voice support |
|---|---|
| Telegram | ✅ `on_voice_message` override, lines 467–525 |
| Matrix | ✅ `on_voice_message` override, lines 507–554 |
| Discord | ❌ base class stub only — audio attachments silently dropped |

Pattern exists in both other connectors. Discord attachments expose `content_type` and an `url` for downloading.

Note: Telegram uses `server.transcribe(path: str)` (file path); Matrix uses `server.transcribe_audio(data: bytes)` (raw bytes). Discord should use the bytes path (no temp file needed) matching Matrix.

### Fix 3 — Ack emoji not removed on Matrix; missing from Discord slash command (High)

| Connector | Ack send | Ack remove |
|---|---|---|
| Telegram | ✅ `set_reaction([ReactionTypeEmoji])` line 421 | ✅ `set_reaction([])` line 463 |
| Discord `on_message` | ✅ `add_reaction` line 218 | ✅ `remove_reaction` line 255 |
| Discord `/chat` slash command | ❌ absent from `_handle_chat` (line 330) | ❌ absent |
| Matrix | ✅ `room_send m.reaction` line 448 | ❌ `pass` stub line 505 |

The issue description says "Discord: ack emoji is never sent" — this is inaccurate. Discord's `on_message` path sends and removes correctly. The gap is only in the `/chat` slash command handler.

Matrix stores no reaction event ID, so can't remove it. Fix: capture the event ID from `room_send` response and call `room_redact()` after response is sent.

### Fix 4 — Discord group history uses API fetch instead of ring buffer (Medium)

| Connector | Group history method |
|---|---|
| Telegram | `GroupHistoryBuffer.record()` + `get_recent()` (in-memory) |
| Matrix | `GroupHistoryBuffer.record()` + `get_recent()` (in-memory) |
| Discord | `channel.history()` API call per message (network round-trip) |

Discord's `_get_group_history()` (lines 379–414) re-implements `format_for_prompt()` inline. Switching to `self.group_history` eliminates the network dependency and uses the same `<group_context>` format automatically.

---

## Technical Approach

### Fix 1: Add `error_occurred` flag to Discord and Matrix

In `discord_bot.py` and `matrix_bot.py`, add the same `error_occurred` flag that Telegram uses in its streaming loop:

```python
# discord_bot.py — _route_to_chat()
error_occurred = False
# ...
elif event_type == "error":
    error_msg = event.get("error", str(event))
    logger.error(f"Orchestrator error event: {error_msg}")
    error_occurred = True
elif event_type == "typed_error":
    # existing code...
    error_occurred = True

# At "no response" fallback:
if not response_text and not error_occurred:
    response_text = "No response from agent."
```

Same pattern for `matrix_bot.py`. Also rename the `msg` variable to `message` in Matrix's `typed_error`/`warning` handling for consistency.

### Fix 2: Add `on_voice_message` to Discord

Discord messages expose audio via `message.attachments`. Check `attachment.content_type` for audio MIME types, download to bytes, transcribe, then feed through the existing text pipeline.

```python
# discord_bot.py — on_voice_message (new method)
async def on_voice_message(self, message, context=None) -> None:
    AUDIO_TYPES = {"audio/ogg", "audio/mpeg", "audio/wav", "audio/webm", "audio/mp4"}
    audio = next(
        (a for a in message.attachments if a.content_type in AUDIO_TYPES),
        None,
    )
    if not audio:
        return

    transcribe = getattr(self.server, "transcribe_audio", None)
    if not transcribe:
        await message.reply("Voice transcription is not configured.")
        return

    data = await audio.read()           # bytes
    text = await transcribe(data)
    if not text:
        await message.reply("Could not transcribe audio.")
        return

    # Re-use existing text message pipeline
    await self._process_message(message, text)
```

Call site: in Discord's `on_message` handler, check `message.attachments` for audio types before the existing text path.

### Fix 3a: Matrix ack remove

Capture the event ID returned by the `room_send` ack call, then `room_redact` it after the response is sent:

```python
# matrix_bot.py — on_text_message
ack_event_id = None
if self.ack_emoji and self._client:
    try:
        resp = await self._client.room_send(
            room_id,
            message_type="m.reaction",
            content={
                "m.relates_to": {
                    "rel_type": "m.annotation",
                    "event_id": event.event_id,
                    "key": self.ack_emoji,
                }
            },
        )
        ack_event_id = getattr(resp, "event_id", None)
    except Exception as e:
        logger.debug(f"Ack reaction failed (non-critical): {e}")

# ... route to orchestrator ...

if ack_event_id and self._client:
    try:
        await self._client.room_redact(room_id, ack_event_id)
    except Exception:
        pass
```

Replace the current `ack_sent` boolean with `ack_event_id: str | None`.

### Fix 3b: Discord `/chat` slash command ack

Discord's `_handle_chat` (line ~282) uses `interaction.response.defer()` but sends no ack emoji. Add emoji send after defer, remove after response:

```python
# discord_bot.py — _handle_chat
ack_sent = False
if self.ack_emoji:
    try:
        await interaction.followup.send(self.ack_emoji, ephemeral=True)
        ack_sent = True
    except Exception:
        pass
# ... generate response ...
# (ephemeral ack is auto-dismissed; no explicit remove needed for ephemeral)
```

Note: Discord ephemeral messages auto-dismiss, so this is simpler than the `on_message` path.

### Fix 4: Discord group history → ring buffer

Remove `_get_group_history()` method from Discord entirely. Add `self.group_history.record()` in `on_message` (for all group messages, including ones the bot won't respond to), and replace `_get_group_history()` call sites with `self.group_history.get_recent()` + `format_for_prompt()`.

```python
# discord_bot.py — on_message (new recording call, before mention gate)
if not message.guild:  # DM
    ...
else:  # Group
    group_msg = GroupMessage(
        user_display=message.author.display_name,
        text=message.content,
        timestamp=message.created_at,
        message_id=message.id,
    )
    self.group_history.record(str(message.channel.id), group_msg)

# Later, when building context:
recent = self.group_history.get_recent(
    str(message.channel.id), exclude_message_id=message.id
)
group_context = self.group_history.format_for_prompt(recent)
```

---

## Acceptance Criteria

- [x] Discord `_route_to_chat()` has `error_occurred` flag; bare `error` event suppresses "No response from agent." fallback
- [x] Matrix `_route_to_chat()` has `error_occurred` flag with same behavior
- [x] Matrix `typed_error`/`warning` handler uses `message` (not `msg`) as local variable name
- [x] Discord `on_voice_message()` is implemented; audio attachments are detected, downloaded, transcribed, and routed to the text pipeline
- [x] Discord `on_message` calls `on_voice_message` when audio attachment is present
- [x] Matrix ack emoji is removed (redacted) after response is sent
- [x] Discord `/chat` slash command sends ack emoji via ephemeral followup
- [x] Discord `_get_group_history()` is deleted; ring buffer used instead
- [x] Discord `on_message` records all group messages to ring buffer regardless of mention gating
- [x] All existing bot connector unit tests pass
- [x] New unit tests for each fix are added to `tests/unit/test_bot_connectors.py`

---

## Implementation Order

The fixes are independent. Recommended order based on risk/impact:

1. **Fix 1** (error_occurred) — smallest diff, highest UX impact, lowest risk
2. **Fix 3a** (Matrix ack remove) — self-contained Matrix-only change
3. **Fix 3b** (Discord slash ack) — self-contained Discord-only change
4. **Fix 4** (Discord ring buffer) — deletes code, adds recording, low risk
5. **Fix 2** (Discord voice) — most new code, do last

---

## References

### Key File Locations

| File | Lines | Notes |
|---|---|---|
| `computer/parachute/connectors/discord_bot.py` | 416–463 | `_route_to_chat()` — error handling |
| `computer/parachute/connectors/discord_bot.py` | 282–343 | `_handle_chat()` — slash command, no ack |
| `computer/parachute/connectors/discord_bot.py` | 379–414 | `_get_group_history()` — to be deleted |
| `computer/parachute/connectors/discord_bot.py` | 214–221 | `on_text_message` ack send |
| `computer/parachute/connectors/matrix_bot.py` | 792–835 | `_route_to_chat()` — error handling |
| `computer/parachute/connectors/matrix_bot.py` | 444–461 | `on_text_message` ack send |
| `computer/parachute/connectors/matrix_bot.py` | 501–505 | ack remove stub (pass) |
| `computer/parachute/connectors/matrix_bot.py` | 507–554 | `on_voice_message` — pattern to copy |
| `computer/parachute/connectors/telegram.py` | 467–525 | `on_voice_message` — reference pattern |
| `computer/parachute/connectors/telegram.py` | 554, 592, 601, 631 | `error_occurred` flag reference |
| `computer/parachute/connectors/base.py` | 48–104 | `GroupHistoryBuffer` — ring buffer class |
| `computer/tests/unit/test_bot_connectors.py` | 1155+ | Existing fix tests — add alongside |

### Related Issues

- #89 — Bot framework production hardening (just shipped) — no overlap
- #49 — Server-side error propagation (structured error events, upstream of connectors)
- #82 — Refactor orchestrator streaming phases
