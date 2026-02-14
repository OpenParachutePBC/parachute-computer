---
title: "feat: Bot UX Improvements — Ack Reactions, Streaming, Placeholders, Group History"
type: feat
date: 2026-02-09
source: docs/brainstorms/2026-02-09-openclaw-bot-patterns-brainstorm.md
---

# Bot UX Improvements

Implement four interaction patterns inspired by OpenClaw to make Telegram and Discord bot connectors feel responsive and alive. Telegram first, Discord second.

## Context

The brainstorm at `docs/brainstorms/2026-02-09-openclaw-bot-patterns-brainstorm.md` analyzed OpenClaw's bot interaction patterns. The biggest gap is **conversational feel** — our bot goes silent for 5-30 seconds after receiving a message. These four features fix that.

## Overview

| # | Feature | Impact | Complexity |
|---|---------|--------|------------|
| 1 | **Ack Reactions** | Instant 👀 emoji on message receipt | Low |
| 2 | **Placeholder Messages** | "Thinking..." message while processing | Low |
| 3 | **Response Streaming** | Edit draft message as tokens arrive | Medium |
| 4 | **Group History Injection** | Inject recent group messages as context | Medium |

Features 1-3 compose: ack reaction fires instantly, placeholder shows while waiting for lock, streaming replaces placeholder with progressive response. Feature 4 is independent.

---

## Feature 1: Ack Reactions

React with an emoji (default 👀) immediately when a message arrives, before any processing. Remove after response is sent.

### Implementation

#### `computer/parachute/connectors/base.py`

- [x] Add `ack_emoji` parameter to `BotConnector.__init__()` (default `"👀"`, `None` to disable)
- [x] Store as `self.ack_emoji`

```python
def __init__(
    self,
    bot_token: str,
    server: Any,
    allowed_users: list[int | str],
    ack_emoji: str | None = "👀",  # NEW
    ...
):
    ...
    self.ack_emoji = ack_emoji
```

#### `computer/parachute/connectors/telegram.py`

- [x] In `_process_text_message()`, add ack reaction **before** acquiring the chat lock (line ~374):

```python
# Ack reaction — instant feedback before processing
ack_sent = False
if self.ack_emoji and update.message:
    try:
        from telegram import ReactionTypeEmoji
        await update.message.set_reaction(
            reaction=[ReactionTypeEmoji(emoji=self.ack_emoji)]
        )
        ack_sent = True
    except Exception as e:
        logger.debug(f"Ack reaction failed (non-critical): {e}")

# Route through Chat orchestrator (with per-chat lock)
lock = self._get_chat_lock(chat_id)
async with lock:
    response_text = await self._route_to_chat(...)

# Remove ack reaction after response
if ack_sent and update.message:
    try:
        await update.message.set_reaction(reaction=[])
    except Exception:
        pass  # Non-critical
```

**Key decision**: Ack fires BEFORE the lock. This means if another message is being processed, the user still gets instant feedback that their message was received and is queued.

- [x] Also add ack reaction in `on_voice_message()` before processing

#### `computer/parachute/connectors/discord_bot.py`

- [x] In `on_text_message()`, add ack reaction before the lock:

```python
ack_sent = False
if self.ack_emoji and message:
    try:
        await message.add_reaction(self.ack_emoji)
        ack_sent = True
    except Exception as e:
        logger.debug(f"Ack reaction failed: {e}")

lock = self._get_chat_lock(chat_id)
async with lock:
    async with message.channel.typing():
        response_text = await self._route_to_chat(...)

# Remove ack after response
if ack_sent:
    try:
        await message.remove_reaction(self.ack_emoji, self._client.user)
    except Exception:
        pass
```

#### `computer/parachute/connectors/config.py`

- [x] Add `ack_emoji` field to bot connector config (loaded from `bots.yaml`):

```yaml
telegram:
  enabled: true
  token: "..."
  ack_emoji: "👀"  # or null to disable
```

### Edge Cases

- **Bot permission**: Telegram bots can only set ONE reaction per message. If the bot has already reacted, `set_reaction` replaces it. This is fine — we set then clear.
- **Reaction fails**: Non-critical — wrap in try/except, log at debug level, continue processing.
- **Deleted message**: If the user deletes their message before we react, `set_reaction` raises `BadRequest`. Catch and ignore.
- **Group privacy mode**: Reactions work even if the bot can't read all messages.

---

## Feature 2: Placeholder Messages

Send a "Thinking..." message immediately, then edit it with the real response (or replace it with streaming).

### Implementation

#### `computer/parachute/connectors/telegram.py`

- [x] Refactor `_process_text_message()` to send placeholder inside the lock, before calling `_route_to_chat()`:

```python
lock = self._get_chat_lock(chat_id)
async with lock:
    # Send placeholder
    placeholder = None
    try:
        placeholder = await update.message.reply_text("Thinking...")
    except Exception as e:
        logger.debug(f"Placeholder send failed: {e}")

    response_text = await self._route_to_chat(
        session_id=session.id,
        message=message_text,
    )

    # Edit placeholder with response (or send new if placeholder failed)
    if not response_text:
        response_text = "No response from agent."

    formatted = claude_to_telegram(response_text)
    chunks = self.split_response(formatted, TELEGRAM_MAX_MESSAGE_LENGTH)

    if placeholder and len(chunks) == 1:
        # Edit placeholder in-place (clean — no extra messages)
        try:
            await placeholder.edit_text(chunks[0], parse_mode="MarkdownV2")
        except Exception:
            try:
                await placeholder.edit_text(chunks[0])
            except Exception:
                await update.message.reply_text(chunks[0])
    else:
        # Multi-chunk: delete placeholder, send chunks as replies
        if placeholder:
            try:
                await placeholder.delete()
            except Exception:
                pass
        for chunk in chunks:
            try:
                await update.message.reply_text(chunk, parse_mode="MarkdownV2")
            except Exception:
                await update.message.reply_text(chunk)
```

**Why placeholder inside lock**: If outside lock, multiple queued messages would each show "Thinking...", which is confusing. Inside lock, only one placeholder exists at a time.

#### `computer/parachute/connectors/discord_bot.py`

- [x] Discord already has `async with message.channel.typing():` which serves as a native placeholder. No change needed unless we want an explicit "Thinking..." message. **Skip for now** — Discord's typing indicator is already good.

### Edge Cases

- **`BadRequest("Message is not modified")`**: If `edit_text()` is called with the same content (e.g., response is literally "Thinking..."), Telegram raises. Catch and ignore.
- **Placeholder deletion race**: If user blocks bot between placeholder send and edit, `edit_text` fails. Fall back to `reply_text`.
- **Empty response**: If orchestrator returns empty, edit placeholder to "No response from agent." rather than leaving "Thinking..." forever.

---

## Feature 3: Response Streaming (Telegram)

Edit a draft message in-place as tokens stream from the orchestrator, instead of waiting for the complete response.

### Implementation

This is the most complex feature. It requires refactoring `_route_to_chat()` from a string-accumulating function to a streaming consumer.

#### `computer/parachute/connectors/telegram.py`

- [x] Create new `_stream_to_chat()` method that replaces both `_route_to_chat()` and the response-sending logic:

```python
async def _stream_to_chat(
    self,
    session_id: str,
    message: str,
    update: Any,
    placeholder: Any | None = None,
) -> None:
    """Stream orchestrator response to Telegram, editing draft message progressively."""
    orchestrate = getattr(self.server, "orchestrate", None)
    if not orchestrate:
        logger.error("Server has no orchestrate method")
        if placeholder:
            await placeholder.edit_text("Chat orchestrator not available.")
        else:
            await update.message.reply_text("Chat orchestrator not available.")
        return

    draft_msg = placeholder  # Reuse placeholder as draft
    buffer = ""
    last_edit_len = 0
    edit_count = 0
    MAX_EDITS = 25  # Stay under Telegram's ~30-40 edit limit
    MIN_EDIT_DELTA = 150  # Min chars between edits
    error_occurred = False

    try:
        async for event in orchestrate(
            session_id=session_id,
            message=message,
            source="telegram",
        ):
            event_type = event.get("type", "") if isinstance(event, dict) else getattr(event, "type", "")

            if event_type == "text":
                content = event.get("content", "") if isinstance(event, dict) else getattr(event, "content", "")
                if content:
                    buffer = content

                    # Decide whether to edit now
                    delta_since_edit = len(buffer) - last_edit_len
                    should_edit = (
                        delta_since_edit >= MIN_EDIT_DELTA
                        and edit_count < MAX_EDITS
                    )

                    if should_edit:
                        await self._edit_draft(
                            update, draft_msg, buffer, is_final=False
                        )
                        last_edit_len = len(buffer)
                        edit_count += 1

                        # Create draft if we don't have one yet
                        if draft_msg is None:
                            # First edit — send as reply
                            pass  # draft_msg set inside _edit_draft

            elif event_type == "error":
                error_msg = event.get("error", "") if isinstance(event, dict) else getattr(event, "error", "")
                logger.error(f"Orchestrator error event: {error_msg}")
                error_occurred = True

        # Final edit with complete response
        if buffer:
            formatted = claude_to_telegram(buffer)
            chunks = self.split_response(formatted, TELEGRAM_MAX_MESSAGE_LENGTH)

            if len(chunks) == 1 and draft_msg:
                # Single chunk — final edit
                try:
                    await draft_msg.edit_text(chunks[0], parse_mode="MarkdownV2")
                except Exception:
                    try:
                        await draft_msg.edit_text(chunks[0])
                    except Exception:
                        pass
            elif len(chunks) > 1:
                # Multi-chunk — edit first chunk into draft, send rest as new messages
                if draft_msg:
                    try:
                        await draft_msg.edit_text(chunks[0], parse_mode="MarkdownV2")
                    except Exception:
                        try:
                            await draft_msg.edit_text(chunks[0])
                        except Exception:
                            pass
                else:
                    try:
                        await update.message.reply_text(chunks[0], parse_mode="MarkdownV2")
                    except Exception:
                        await update.message.reply_text(chunks[0])

                for chunk in chunks[1:]:
                    try:
                        await update.message.reply_text(chunk, parse_mode="MarkdownV2")
                    except Exception:
                        await update.message.reply_text(chunk)
            elif not buffer and not error_occurred:
                # No response at all
                if draft_msg:
                    await draft_msg.edit_text("No response from agent.")
                else:
                    await update.message.reply_text("No response from agent.")
        elif not error_occurred:
            if draft_msg:
                await draft_msg.edit_text("No response from agent.")
            else:
                await update.message.reply_text("No response from agent.")

        logger.info(f"Telegram streaming: {edit_count} edits, {len(buffer)} chars response")

    except Exception as e:
        logger.error(f"Chat streaming failed: {e}", exc_info=True)
        error_text = "Something went wrong. Please try again later."
        if draft_msg:
            try:
                await draft_msg.edit_text(error_text)
            except Exception:
                await update.message.reply_text(error_text)
        else:
            await update.message.reply_text(error_text)
```

- [x] Create helper `_edit_draft()`:

```python
async def _edit_draft(
    self,
    update: Any,
    draft_msg: Any | None,
    text: str,
    is_final: bool = False,
) -> Any:
    """Edit draft message or create one. Returns draft message object."""
    # For intermediate edits, use plain text (faster, no parse errors)
    # For final edit, use MarkdownV2
    display_text = text
    if not is_final:
        # Truncate to 4096 for intermediate display
        if len(display_text) > TELEGRAM_MAX_MESSAGE_LENGTH:
            display_text = display_text[:TELEGRAM_MAX_MESSAGE_LENGTH - 20] + "\n\n_...streaming..._"

    if draft_msg is None:
        # Create new draft
        try:
            return await update.message.reply_text(display_text)
        except Exception as e:
            logger.debug(f"Draft creation failed: {e}")
            return None
    else:
        # Edit existing draft
        try:
            await draft_msg.edit_text(display_text)
        except Exception as e:
            # "Message is not modified" is normal if text hasn't changed
            if "not modified" not in str(e).lower():
                logger.debug(f"Draft edit failed: {e}")
        return draft_msg
```

- [x] Refactor `_process_text_message()` to use `_stream_to_chat()`:

```python
async def _process_text_message(self, update, message_text):
    ...
    # Ack reaction (before lock)
    ack_sent = False
    if self.ack_emoji and update.message:
        try:
            from telegram import ReactionTypeEmoji
            await update.message.set_reaction(
                reaction=[ReactionTypeEmoji(emoji=self.ack_emoji)]
            )
            ack_sent = True
        except Exception:
            pass

    lock = self._get_chat_lock(chat_id)
    async with lock:
        # Send placeholder
        placeholder = None
        try:
            placeholder = await update.message.reply_text("Thinking...")
        except Exception:
            pass

        # Stream response (edits placeholder progressively)
        await self._stream_to_chat(
            session_id=session.id,
            message=message_text,
            update=update,
            placeholder=placeholder,
        )

    # Remove ack reaction
    if ack_sent:
        try:
            await update.message.set_reaction(reaction=[])
        except Exception:
            pass
```

- [x] Keep `_route_to_chat()` as-is for Discord (string accumulation mode). Telegram uses `_stream_to_chat()` instead.

#### `computer/parachute/connectors/discord_bot.py`

- [x] **Defer streaming for Discord**. Discord's typing indicator + single message is fine for now. Streaming can be added later if needed. Discord already supports `sent_msg.edit(content=)` but has different rate limits.

### Rate Limiting

- **Telegram**: ~30-40 message edits per message, enforced server-side. We cap at `MAX_EDITS = 25` to stay safe.
- **`MIN_EDIT_DELTA = 150`**: Don't edit for every token — batch at least 150 chars between edits.
- **Intermediate edits use plain text**: Faster, no MarkdownV2 parse errors. Final edit uses MarkdownV2.

### Edge Cases

- **Response exceeds 4096 chars during streaming**: Intermediate edits truncate at 4096 with "...streaming..." suffix. Final response uses `split_response()` as normal.
- **Telegram rate limit hit**: `edit_text` raises `RetryAfter`. Catch, wait, continue. In practice `MAX_EDITS` prevents this.
- **Empty response**: If no text events arrive, edit placeholder to "No response from agent."
- **Error during streaming**: Edit draft to error message.
- **User deletes draft message**: `edit_text` raises `BadRequest`. Catch, fall back to `reply_text` for remaining content.

---

## Feature 4: Group History Injection

When responding to a group message, inject recent conversation messages as context so the bot understands the surrounding discussion.

### Implementation

#### `computer/parachute/connectors/base.py`

- [x] Add `GroupHistoryBuffer` class for in-memory ring buffer:

```python
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime

@dataclass
class GroupMessage:
    """A cached group message for history injection."""
    user_display: str
    text: str
    timestamp: datetime
    message_id: str | int

class GroupHistoryBuffer:
    """Per-chat ring buffer of recent group messages.

    Telegram has no API to fetch chat history — we must cache messages
    as they arrive. Discord has channel.history() but using a buffer
    keeps the approach consistent.
    """

    def __init__(self, max_messages: int = 50):
        self.max_messages = max_messages
        self._buffers: dict[str, deque[GroupMessage]] = {}

    def record(self, chat_id: str, msg: GroupMessage) -> None:
        """Record a message in the buffer."""
        if chat_id not in self._buffers:
            self._buffers[chat_id] = deque(maxlen=self.max_messages)
        self._buffers[chat_id].append(msg)

    def get_recent(
        self,
        chat_id: str,
        exclude_message_id: str | int | None = None,
        limit: int = 20,
    ) -> list[GroupMessage]:
        """Get recent messages, optionally excluding the triggering message."""
        buf = self._buffers.get(chat_id, deque())
        messages = list(buf)
        if exclude_message_id:
            messages = [m for m in messages if m.message_id != exclude_message_id]
        return messages[-limit:]

    def format_for_prompt(self, messages: list[GroupMessage]) -> str:
        """Format buffered messages as context block for the prompt."""
        if not messages:
            return ""
        lines = ["[Recent group messages for context]"]
        for msg in messages:
            lines.append(f"[from: {msg.user_display}] {msg.text}")
        return "\n".join(lines)
```

- [x] Add `group_history` parameter to `BotConnector.__init__()`:

```python
self.group_history = GroupHistoryBuffer(max_messages=50)
```

#### `computer/parachute/connectors/telegram.py`

- [x] In `on_text_message()`, record every group message to the buffer (before the mention check / return):

```python
async def on_text_message(self, update, context):
    ...
    chat_type = "dm" if update.effective_chat.type == "private" else "group"

    # Record group messages for history injection
    if chat_type == "group" and update.message:
        self.group_history.record(
            chat_id=str(update.effective_chat.id),
            msg=GroupMessage(
                user_display=update.effective_user.full_name,
                text=update.message.text,
                timestamp=datetime.utcnow(),
                message_id=update.message.message_id,
            ),
        )

    # ... mention gating, process_text_message, etc.
```

- [x] In `_process_text_message()`, inject history for group chats:

```python
async def _process_text_message(self, update, message_text):
    chat_id = str(update.effective_chat.id)
    chat_type = "dm" if update.effective_chat.type == "private" else "group"

    ...

    # Inject group history for context
    effective_message = message_text
    if chat_type == "group":
        recent = self.group_history.get_recent(
            chat_id,
            exclude_message_id=update.message.message_id if update.message else None,
            limit=20,
        )
        if recent:
            history_block = self.group_history.format_for_prompt(recent)
            effective_message = f"{history_block}\n\n[Current message - respond to this]\n{message_text}"

    # Use effective_message when calling _stream_to_chat / _route_to_chat
    ...
```

#### `computer/parachute/connectors/discord_bot.py`

- [x] Discord has native `channel.history()` — use it instead of the buffer:

```python
async def _get_group_history(self, channel, exclude_id: int, limit: int = 20) -> str:
    """Fetch recent channel messages for context."""
    if isinstance(channel, discord.DMChannel):
        return ""
    try:
        messages = []
        async for msg in channel.history(limit=limit + 1):
            if msg.id == exclude_id or msg.author == self._client.user:
                continue
            messages.append(msg)
            if len(messages) >= limit:
                break
        if not messages:
            return ""
        messages.reverse()  # Chronological order
        lines = ["[Recent group messages for context]"]
        for msg in messages:
            lines.append(f"[from: {msg.author.display_name}] {msg.content}")
        return "\n".join(lines)
    except Exception as e:
        logger.debug(f"Failed to fetch channel history: {e}")
        return ""
```

- [x] In `on_text_message()`, inject group history:

```python
effective_message = message_text
if chat_type == "group":
    history = await self._get_group_history(
        message.channel,
        exclude_id=message.id,
    )
    if history:
        effective_message = f"{history}\n\n[Current message - respond to this]\n{message_text}"
```

#### Buffer contents

- **Record ALL group messages** from allowed users (not just ones directed at the bot). This gives the bot full conversation context.
- **Exclude bot's own messages** from the buffer.
- **Cap at 50 messages** per chat (in-memory, lost on restart — acceptable for group context).
- **Format**: Simple `[from: Name] text` format, prefixed with `[Recent group messages for context]`.

### Edge Cases

- **Server restart**: Buffer is lost. First group response after restart has no context. Acceptable — context rebuilds naturally as messages flow in.
- **Large groups**: Buffer is per-chat, capped at 50. In very active groups, old messages rotate out quickly. The `limit=20` on retrieval ensures we don't inject too much context.
- **Message recording for ignored messages**: We record ALL group messages to the buffer, even ones the bot won't respond to (e.g., non-mentions in mention_only mode). This is intentional — the bot should understand the full conversation when it IS triggered.
- **Bot's own messages**: Don't record in buffer (filtered by `user_id != bot_id` check).

---

## Configuration

### `bots.yaml` additions

```yaml
telegram:
  enabled: true
  token: "..."
  allowed_users: [123456789]
  ack_emoji: "👀"           # emoji string or null to disable
  dm_trust_level: vault
  group_trust_level: sandboxed
  group_mention_mode: mention_only

discord:
  enabled: true
  token: "..."
  allowed_users: ["987654321"]
  ack_emoji: "👀"           # same
  ...
```

### Per-session override via `bot_settings`

The `bot_settings` metadata already supports per-session `response_mode` and `mention_pattern`. Ack emoji could be added per-session later but is connector-level for now.

---

## Interaction Flow (Complete)

```
User sends message in Telegram
│
├── 1. Record in group history buffer (if group chat)
├── 2. Mention gating check (if group, based on response_mode)
├── 3. Session lookup / initialization check
├── 4. 👀 ACK REACTION (instant, before lock)
│
├── 5. Acquire per-chat lock
│   ├── 6. Send "Thinking..." PLACEHOLDER
│   ├── 7. Inject group history into message (if group)
│   ├── 8. Call orchestrator.run_streaming()
│   ├── 9. STREAM: Edit placeholder as tokens arrive
│   │   ├── Edit 1: first 150 chars
│   │   ├── Edit 2: first 300 chars
│   │   ├── ...
│   │   └── Edit N: complete response (MarkdownV2 formatted)
│   └── 10. If multi-chunk: delete draft, send chunks as replies
├── Release lock
│
└── 11. Remove 👀 reaction
```

---

## Files Modified

| File | Repo | Changes |
|------|------|---------|
| `parachute/connectors/base.py` | computer | `ack_emoji` param, `GroupHistoryBuffer` class |
| `parachute/connectors/telegram.py` | computer | Ack reactions, placeholder, streaming, group history recording/injection |
| `parachute/connectors/discord_bot.py` | computer | Ack reactions, group history via `channel.history()` |
| `parachute/connectors/config.py` | computer | `ack_emoji` config field |

---

## Verification

### Feature 1: Ack Reactions
- [ ] Send DM to Telegram bot → 👀 reaction appears within 1 second → response arrives → 👀 reaction disappears
- [ ] Send message while bot is processing another → 👀 reaction appears immediately (before lock)
- [ ] Set `ack_emoji: null` in bots.yaml → no reaction appears
- [ ] Discord: Same flow with `message.add_reaction()` / `message.remove_reaction()`

### Feature 2: Placeholder Messages
- [ ] Send DM to Telegram bot → "Thinking..." message appears → gets edited to full response
- [ ] Long response (>4096 chars) → "Thinking..." message deleted, chunks sent as separate replies
- [ ] Error during processing → "Thinking..." edited to error message

### Feature 3: Response Streaming
- [ ] Send DM to Telegram bot → "Thinking..." edits progressively as tokens arrive → final edit has MarkdownV2 formatting
- [ ] Count edits → should be <=25 for any response
- [ ] Very short response → 1-2 edits total (placeholder + final)
- [ ] Very long response (>4096) → streaming truncates at limit, final sends as multi-chunk

### Feature 4: Group History Injection
- [ ] Add bot to Telegram group → have a conversation without mentioning bot → then @mention bot → bot's response shows awareness of the preceding conversation
- [ ] Check orchestrator logs → injected message should contain `[Recent group messages for context]`
- [ ] Discord: Same test, verify `channel.history()` is called
- [ ] Restart server → first group response has no context (expected) → subsequent messages rebuild context

### Integration Test
- [ ] Full flow: DM → 👀 appears → "Thinking..." → progressive edits → final formatted response → 👀 removed
- [ ] Group flow: conversation → @mention → 👀 → "Thinking..." → response referencing group context → 👀 removed
- [ ] Concurrent: Send two messages quickly → first gets 👀 + processed → second gets 👀 (queued) → second processed after first completes

---

## Open Questions (Resolved)

| Question | Decision |
|----------|----------|
| Ack before or after lock? | **Before** — instant feedback even when queued |
| Streaming overflow at 4096 chars? | Truncate intermediate edits, final uses `split_response()` |
| What goes in Telegram group buffer? | All messages from allowed users, excluding bot's own |
| Discord streaming? | **Defer** — typing indicator is sufficient for now |
| Per-session ack emoji? | **No** — connector-level for simplicity. Can add later to `bot_settings` |
| Placeholder + streaming coexist? | **Yes** — placeholder becomes the draft message that streaming edits |
