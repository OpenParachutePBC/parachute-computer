---
title: OpenClaw Bot Patterns Analysis
type: research
date: 2026-02-09
---

# OpenClaw Bot Patterns Analysis

Deep comparison of OpenClaw's architecture with Parachute's bot connector system to identify patterns worth adopting, with focus on user-facing interaction patterns.

## What is OpenClaw?

OpenClaw (formerly Clawdbot/Moltbot) is an open-source TypeScript AI agent gateway by Peter Steinberger. 150k+ GitHub stars. Runs locally, connects to 12+ messaging platforms (WhatsApp, Telegram, Discord, Slack, Signal, iMessage, Teams, Matrix, etc.), and routes messages to LLM agents that can execute tools.

**Key architectural difference from Parachute**: OpenClaw is a *gateway* — the messaging platforms are the primary interface. Parachute is an *app* — the Flutter client is primary, bots are secondary connectors. This shapes every design decision.

---

## Architecture Comparison

### OpenClaw: Hub-and-Spoke Gateway

```
Channel Adapters (12+)
    ↓ normalized messages
Gateway Server (WebSocket, port 18789)
    ↓ session routing
Agent Runner (tool loop, ~20 turns)
    ↓ LLM calls
Model Providers (Claude, OpenAI, Ollama, etc.)
```

- **Gateway is always-on**, channels connect into it
- TypeScript, ~40k lines
- Single JSON5 config file (`~/.openclaw/openclaw.json`)
- JSONL session transcripts + Markdown memory files
- Lane-based concurrency (serial by default, explicit parallel)
- Skills = SKILL.md files injected into system prompt

### Parachute: App with Bot Connectors

```
Flutter App (primary UI)
    ↓ HTTP/SSE
FastAPI Server
    ↓ orchestrator
Claude Agent SDK
    ↑
Bot Connectors (Telegram, Discord)
    ↓ also route through orchestrator
```

- **App is primary**, bots are secondary entry points
- Python, modular (brain/chat/daily modules)
- YAML config (`bots.yaml`) + SQLite metadata
- SDK-managed JSONL transcripts
- Per-chat asyncio locks (serial per chat)
- Modules = Python packages with manifest.yaml

---

## User Interaction Patterns (The Good Stuff)

### 1. Acknowledgment Reactions (ackReaction)

**OpenClaw's killer UX pattern.** When a user sends a message, the bot *immediately* reacts with an emoji (e.g., 👀) before processing begins. After the response is sent, the reaction is removed.

```json
{
  "whatsapp": {
    "ackReaction": {
      "emoji": "👀",
      "direct": true,
      "group": "mentions"
    }
  }
}
```

**How it works:**
1. User sends message
2. Bot instantly reacts with 👀 emoji (before typing indicator, before any processing)
3. Agent processes message, generates response
4. Bot sends response
5. Bot removes the 👀 reaction (if `removeAckAfterReply: true`)

**Configuration options:**
- `emoji`: Any emoji (👀, ✅, 📨, 🧠, etc.)
- `direct` (bool): Whether to ack in DMs
- `group`: `"always"` | `"mentions"` | `"never"` — when to ack in groups

**Why this is great:**
- **Instant feedback** — user knows message was received within milliseconds
- **No false promises** — unlike "thinking..." text, a reaction doesn't imply imminent response
- **Clean** — reactions don't clutter the conversation like placeholder messages
- **Platform-native** — uses the messaging platform's own reaction feature
- **Configurable** — can be disabled per-context

**Parachute comparison**: We use `message.channel.typing()` (Discord) and `ChatAction.TYPING` (Telegram) for typing indicators, but these have limitations:
- Telegram typing indicators expire after 5 seconds and must be refreshed
- They only show during active processing, not during the initial queue wait
- No instant acknowledgment — if the lock is held by another message, user gets no feedback

### 2. Reply Threading Modes

**OpenClaw**: Configurable `replyToMode` per channel:
- `"off"` — send as new message (no threading)
- `"first"` (default) — reply to the user's triggering message only
- `"all"` — reply to every user message, creating a visual thread

```json
{
  "telegram": {
    "replyToMode": "first"
  }
}
```

Special syntax in agent responses:
- `[[reply_to_current]]` — reply to the triggering message
- `[[reply_to:<id>]]` — reply to a specific message ID

**Parachute comparison**: We always use `message.reply()` which quotes the triggering message. This is equivalent to OpenClaw's `"first"` mode. We don't offer `"off"` or `"all"`.

**Interesting consideration**: For long multi-turn conversations in groups, always-reply creates visual clutter. An "off" mode where the bot just sends to the channel (without quoting) might be cleaner for dedicated bot channels.

### 3. Response Streaming (Draft Mode)

**OpenClaw**: Three stream modes for Telegram:
- `"off"` — single complete message when done
- `"partial"` (default) — edits a draft message as tokens stream in
- `"block"` — sends separate messages per tool result/thinking block

```json
{
  "telegram": {
    "streamMode": "partial",
    "draftChunk": {
      "minChars": 200,
      "maxChars": 800,
      "breakPreference": "paragraph"
    }
  }
}
```

**How partial streaming works:**
1. Bot sends initial draft message (e.g., first 200 chars)
2. As LLM streams tokens, bot edits the message in-place
3. Telegram has a limit of ~30-40 edits per message
4. Final edit contains complete response

**Important limitation**: Draft streaming is DM-only — Telegram doesn't support it in groups.

**Parachute comparison**: We send one complete message after the orchestrator finishes. No streaming to the chat platform. This means users see typing indicator for the full processing time (could be 10-30 seconds), then get the complete response at once.

### 4. Reaction-Based Input

**OpenClaw**: When users react to the bot's messages with emoji, those reactions are captured and injected into the session context for the next agent turn.

Configurable via `reactionNotifications`:
- `"off"` — ignore all reactions
- `"own"` — only notify when someone reacts to bot's messages
- `"allowlist"` — notify for allowlisted users' reactions
- `"all"` — notify for all reactions

The agent sees: `"Signal reaction added: 👍 by Ada Lovelace (@ada) msg 123"`

**Parachute comparison**: We don't capture or process user reactions at all. Reactions are invisible to the agent.

### 5. Inline Buttons (Telegram)

**OpenClaw**: Agents can send inline keyboard buttons. Users press buttons, callback queries are routed back to the agent as messages.

```json
{
  "action": "send",
  "channel": "telegram",
  "to": "123456789",
  "message": "Choose an option:",
  "buttons": [[
    { "text": "Yes", "callback_data": "yes" },
    { "text": "No", "callback_data": "no" }
  ]]
}
```

Scoping: `"off"` | `"dm"` | `"group"` | `"all"` | `"allowlist"`

**Parachute comparison**: We have the `userQuestion` event type in our SSE stream (for the app UI), but we don't translate those into platform-native interactive elements for bot users. When Claude asks a clarifying question via the SDK, the bot user just sees the question as text and has to type a response.

### 6. Group History Injection

**OpenClaw (WhatsApp)**: When responding to a group message, the bot injects recent unprocessed messages (default 50) as context:

```
[Chat messages since your last reply - for context]
[from: Alice (+15551234567)]
Can anyone help with the deployment?

[from: Bob (+15559876543)]
I think the issue is the env vars

[Current message - respond to this]
[from: Carol (+15555550123)]
@bot can you check the logs?
```

**Parachute comparison**: We don't inject group conversation history. The bot only sees the message directly sent to it (or mentioning it). This means in group chats, the bot has no awareness of the surrounding conversation.

### 7. Placeholder/Loading Messages

**OpenClaw (community-requested)**: Configurable placeholder messages shown before the response:

```json
{
  "placeholderMessage": {
    "enabled": true,
    "messages": ["🧠 Thinking...", "💭 Processing..."],
    "deleteOnResponse": true
  }
}
```

The bot sends a placeholder immediately, then deletes it and sends the real response. Randomly picks from the messages list for personality.

**Parachute comparison**: We don't send placeholder messages. Users see only the typing indicator.

### 8. Text Chunking Strategy

**OpenClaw**: Platform-specific limits with paragraph-aware splitting:
- `textChunkLimit`: Max chars per message (4000 for Telegram, 2000 for Discord)
- `chunkMode: "newline"`: Prefer splitting on blank lines before hard-cutting at char limit

**Parachute comparison**: Our `split_response()` in `base.py` splits at paragraph boundaries and respects code blocks. Similar approach but OpenClaw's config makes limits adjustable per-channel.

---

## Infrastructure Patterns

### 9. Channel/Connector Architecture

**OpenClaw**: Formal adapter with `StandardMessage` interface. New channels are plugins.

**Parachute**: Abstract `BotConnector` base class. Messages go through orchestrator as strings.

**Verdict**: Our approach is fine for 2 connectors. Consider standardized message envelope when adding a 3rd.

### 10. Concurrency: Message Collection

**OpenClaw**: `collect` queue mode debounces rapid messages into one batch.

**Parachute**: Each message processed independently with per-chat lock.

**Worth considering**: Batching 3 rapid Telegram messages into one prompt saves API calls. But adds latency to every single message (must wait for debounce timeout even for lone messages).

### 11. Sequential Processing

**OpenClaw (Telegram)**: Uses grammY's `sequentialize()` middleware with composite keys:
- `telegram:{chatId}` — private chats
- `telegram:{chatId}:topic:{threadId}` — forum topics
- `telegram:{chatId}:control` — fast path for commands

**Parachute**: Per-chat asyncio locks keyed on `chat_id`. Same effect, simpler implementation.

### 12. Access Control & Pairing

**OpenClaw**: CLI-based approval (`openclaw pairing approve`). Three DM policies.

**Parachute**: App-based approval with pairing requests visible in Flutter UI. Nicer UX.

**Verdict**: Our approach is better for non-technical users.

---

## Patterns Worth Adopting (Revised Priority)

### Tier 1: High Impact, Make the Bot Feel Alive

#### 1. Acknowledgment Reactions (ackReaction)

The single most impactful UX improvement. When a message comes in:
1. Immediately react with 👀 (or configurable emoji)
2. Start processing
3. Remove reaction after sending response

**Implementation sketch:**
```python
# In TelegramConnector._process_text_message(), before acquiring lock:
ack_msg = await update.message.set_reaction(
    reaction=[ReactionTypeEmoji(emoji="👀")]
)

# After response is sent:
await update.message.set_reaction(reaction=[])  # Remove reaction
```

For Discord: `await message.add_reaction("👀")` / `await message.remove_reaction("👀")`

**Configurable via bot_settings:**
```python
"bot_settings": {
    "ack_reaction": "👀",  # emoji or null to disable
    "ack_in_groups": "mentions",  # "always" | "mentions" | "never"
}
```

**Why this matters**: The bot currently goes silent for 5-30 seconds after receiving a message. The user has no idea if it was received. An instant emoji reaction says "got it, working on it" without cluttering the chat.

#### 2. Response Streaming to Telegram (Partial Mode)

Edit a draft message as tokens stream in, rather than sending one big message at the end.

**Implementation sketch:**
```python
# In TelegramConnector._route_to_chat():
draft_msg = None
buffer = ""

async for event in orchestrate(session_id=session_id, message=message):
    if event.get("type") == "text":
        buffer += event.get("delta", "")
        if len(buffer) >= 200:  # Min chunk size
            if draft_msg is None:
                draft_msg = await update.message.reply_text(buffer)
            else:
                await draft_msg.edit_text(buffer)
```

**Limitations**: Telegram allows ~30-40 edits per message. DM-only for draft mode. Need rate limiting on edits (not every token, batch to ~200 char chunks).

**Parachute advantage**: Our orchestrator already yields SSE events with deltas. We just need to forward them to the platform instead of accumulating.

#### 3. Placeholder Messages (Simple Version)

Before the ack reaction pattern, even simpler: send a "thinking..." message immediately, replace it with the real response.

```python
placeholder = await update.message.reply_text("💭 Thinking...")
# ... process ...
await placeholder.edit_text(formatted_response)
```

**Tradeoff with streaming**: If we implement streaming (#2), placeholder becomes unnecessary. Streaming subsumes it. But placeholder is much simpler to implement as a first step.

### Tier 2: Nice UX Improvements

#### 4. Group History Injection

Before processing a group message, inject recent conversation messages as context so the bot understands the surrounding discussion.

**Implementation**: Use Telegram/Discord APIs to fetch recent messages in the channel, format them into a context block prepended to the user's message.

#### 5. Reply Mode Configuration

Per-session setting for `"reply"` (default, quote original) vs `"sequential"` (just send to channel). Useful for dedicated bot channels where quoting every message is noisy.

#### 6. Reaction Capture

When users react to bot messages with emoji (👍, 👎, ❤️), capture those as feedback. Could be used for:
- Thumbs up/down as quality signal
- Heart as "save this" trigger
- Custom reactions mapped to actions

### Tier 3: Consider Later

#### 7. Message Debouncing

Batch rapid messages. Adds complexity and latency for marginal gain.

#### 8. Inline Buttons for User Questions

When Claude asks a clarifying question via `userQuestion` event, translate to Telegram inline buttons instead of requiring typed response. Nice but complex.

#### 9. Discord Thread Mode

Create threads for group conversations. Clean but low priority with current usage patterns.

---

## Patterns NOT Worth Adopting

| Pattern | Why Not |
|---------|---------|
| Hub-and-spoke gateway | We're app-first, not gateway-first |
| Multi-account per platform | Overkill for personal use |
| Single config file | Our app-managed config is better UX |
| Session idle timeout | Our architecture is different — sessions are tied to the Parachute app, not ephemeral bot contexts. Users manage sessions through the app. |
| Lane queue modes | Per-chat locks already give us sequential mode |
| Tool policy hierarchy | Trust levels sufficient for now |

---

## Key Insight

The biggest gap between Parachute and OpenClaw isn't architecture — it's **conversational feel**. OpenClaw makes bot interactions feel responsive and alive through:

1. **Instant acknowledgment** (ack reactions)
2. **Progressive response** (streaming/drafts)
3. **Context awareness** (group history injection)
4. **Interactive elements** (inline buttons, reaction capture)

These are all about making the messaging platform feel like a first-class interface rather than a dumb pipe. Since Parachute is app-first, bots will always be secondary — but they should still feel good to use.

The implementation priority should be:
1. Ack reactions (instant, cheap, huge UX win)
2. Response streaming OR placeholder messages (progressive feedback)
3. Group history injection (better context = better responses)

Everything else is polish.

---

## Open Questions

1. Should ack reaction emoji be configurable per-session in the app, or per-connector?
2. For streaming, should we use Telegram's edit-in-place or send chunks as separate messages?
3. Group history: how many messages to inject? All since last bot reply? Last N?
4. Should we capture user reactions on bot messages as feedback signals?
5. Is there value in translating `userQuestion` events to inline buttons for Telegram?

## Sources

- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
- [OpenClaw Architecture Deep Dive (DeepWiki)](https://deepwiki.com/openclaw/openclaw)
- [OpenClaw Channels (DeepWiki)](https://deepwiki.com/openclaw/openclaw/8-channels)
- [OpenClaw Telegram Integration (DeepWiki)](https://deepwiki.com/openclaw/openclaw/8.3-telegram-integration)
- [OpenClaw Three-Layer Architecture Guide](https://eastondev.com/blog/en/posts/ai/20260205-openclaw-architecture-guide/)
- [How OpenClaw Works (VibeCodCamp)](https://vibecodecamp.blog/blog/everyone-talks-about-clawdbot-openclaw-but-heres-how-it-works)
- [OpenClaw WhatsApp Docs](https://docs.openclaw.ai/channels/whatsapp)
- [OpenClaw Signal Docs](https://docs.openclaw.ai/channels/signal)
- [OpenClaw Telegram Docs](https://openclaw.im/docs/channels/telegram)
- [Placeholder Loading Issue #3849](https://github.com/openclaw/openclaw/issues/3849)
- [Typing Indicator TTS Issue #5637](https://github.com/openclaw/openclaw/issues/5637)
- [Stop-Typing on NO_REPLY Issue #8785](https://github.com/openclaw/openclaw/issues/8785)
- [Auto-Ack Feature Request Issue #8285](https://github.com/openclaw/openclaw/issues/8285)
- [What is OpenClaw (DigitalOcean)](https://www.digitalocean.com/resources/articles/what-is-openclaw)
- [OpenClaw Wikipedia](https://en.wikipedia.org/wiki/OpenClaw)
