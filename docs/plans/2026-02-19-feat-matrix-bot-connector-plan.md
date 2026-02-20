---
title: "feat: Matrix bot connector"
type: feat
date: 2026-02-19
issue: 76
---

# Matrix Bot Connector

## Overview

Add a Matrix protocol bot connector to Parachute, following the existing Telegram/Discord connector pattern. The bot joins Matrix rooms as a regular Matrix user and participates in group conversations. The primary use case: a philosophical companion bot that hangs out in a group chat with multiple people and can be shaped via its Parachute workspace.

Matrix is added **alongside** existing Telegram/Discord connectors, not replacing them. Users on other platforms (Messenger, Signal, etc.) can participate via mautrix bridges configured on the Matrix homeserver — that bridging infrastructure is outside Parachute's scope.

## Problem Statement / Motivation

The original goal was a Facebook Messenger group chat bot. Research revealed that **Meta's Messenger Platform API does not support bots in group chats** (discontinued in 2017). Matrix solves this directly:

- Group chat bots are first-class citizens in the protocol
- Open, federated protocol aligns with Parachute's interoperability principles
- mautrix bridges allow Messenger/Signal/WhatsApp users to join via the Matrix room
- Active Python SDK (matrix-nio v0.25.2) with async support
- The bot appears as a regular room participant — natural for the philosophical companion use case

## Proposed Solution

A `MatrixConnector` subclass of `BotConnector` using the `matrix-nio` async SDK. The connector runs a `sync_forever()` loop (similar to Telegram's polling pattern), receives room events, and responds through the orchestrator.

### Architecture

```
Parachute Server (localhost:3333)
    │
    ├── TelegramConnector (existing, unchanged)
    ├── DiscordConnector (existing, unchanged)
    └── MatrixConnector (NEW)
            │
            └── matrix-nio → sync_forever() → Matrix Homeserver
                                                    │
                                            ┌───────┼───────┐
                                            │       │       │
                                        Native   mautrix  mautrix
                                        Matrix   -meta    -signal
                                        users    bridge   bridge
```

## Technical Approach

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| SDK | `matrix-nio` (raw, no framework) | Async, well-documented, matches pattern of other connectors using platform SDKs directly |
| Transport | `sync_forever()` long-poll | Similar to Telegram's polling; matrix-nio handles the sync loop |
| Auth model | Hybrid: room-level for groups, user-level for DMs | In allowed rooms, everyone can talk. DMs use existing pairing workflow. |
| E2EE | Not in v1 | Significant complexity (crypto store, key verification). Unencrypted rooms only. |
| Initial sync | Ignore backfilled messages | Only process messages arriving after `start()`. Matches Telegram's `drop_pending_updates=True`. |
| Sync persistence | SqliteStore in `vault/.parachute/matrix/` | Fast restarts, no re-processing of old events |
| Streaming | One final message (like Discord) | Matrix edit-in-place is less polished across clients; simpler approach first |
| Message format | Claude markdown → Matrix HTML | Matrix supports a useful HTML subset: bold, italic, code, pre, blockquote, lists, links, headings |
| Message limit | 25,000 characters (conservative) | Matrix event limit is 65KB for full JSON; 25K text leaves room for HTML + metadata |
| Commands | `!new`, `!help`, `!journal` prefix | No native command system in Matrix; prefix detection is the convention |
| Mention gating | `m.mentions` field + display name/MXID fallback | Modern `m.mentions` first, fall back to text matching |
| Typing indicators | Yes | Send `typing_on` while processing, auto-clears on message send |
| Read receipts | No | Reveals processing state, not desired for all use cases |
| Reactions (ack) | Yes, via `m.reaction` event | Consistent with Telegram/Discord ack_emoji pattern |

### Config Model

```yaml
# vault/.parachute/bots.yaml
matrix:
  enabled: true
  homeserver_url: "https://matrix.example.org"
  user_id: "@parachute:example.org"
  access_token: "syt_..."
  device_id: "PARACHUTE01"          # For sync store identity
  allowed_rooms:                     # Room IDs or aliases; empty = accept all invites
    - "!abc123:example.org"
    - "#philosophy:example.org"
  dm_trust_level: "untrusted"        # Trust for DM conversations
  group_trust_level: "untrusted"     # Trust for group rooms
  group_mention_mode: "mention_only" # "mention_only" or "all_messages"
  ack_emoji: "👀"                    # Reaction on received messages
```

Three notable differences from Telegram/Discord config:
- `homeserver_url` + `user_id` + `access_token` instead of single `bot_token`
- `allowed_rooms` instead of `allowed_users` (room-level gating for groups)
- `device_id` for matrix-nio sync store identity

### Authorization Model (Hybrid)

**Group rooms:** Gated by `allowed_rooms`. Anyone in an allowed room can talk to the bot. No per-user checks within a room — the room membership IS the authorization. This is the right model for "a bot that hangs out with a group of friends."

**DMs:** Use the existing user-level pairing workflow. When someone DMs the bot, `handle_unknown_user()` creates a pairing request. Owner approves/denies in the Parachute app.

**Room invites:** When invited to a room NOT in `allowed_rooms`:
- Invite-only rooms: auto-join and create a "pending room" notification (like user pairing)
- Public rooms: ignore silently

### Implementation Phases

#### Phase 1: Core Connector

**New files:**
- `computer/parachute/connectors/messenger.py` → rename to `computer/parachute/connectors/matrix_bot.py`

Actually, the new file:
- `computer/parachute/connectors/matrix_bot.py` — `MatrixConnector` class

**What it does:**
- Subclasses `BotConnector`
- `__init__`: creates `AsyncClient` from config, sets up SqliteStore for sync persistence
- `start()`: clears stop event, launches `_run_with_reconnect()` as background task
- `stop()`: sets stop event, calls `client.close()`, cancels task
- `_run_loop()`: calls `client.sync_forever(timeout=30000)` with callbacks registered
- `on_text_message()`: receives `RoomMessageText` events, applies mention gating, routes to orchestrator
- `on_voice_message()`: receives `RoomMessageAudio` events, downloads via `client.download()`, transcribes
- `send_message()`: sends `m.room.message` events with both plain `body` and HTML `formatted_body`
- `send_approval_message()` / `send_denial_message()`: send DM responses for pairing workflow
- Room invite handler: auto-join allowed rooms, create pending notification for others
- Command handler: detect `!new`, `!help`, `!journal` prefixes in messages
- Ack reactions: add/remove `m.reaction` events
- Typing indicators: `PUT /rooms/{roomId}/typing/{userId}` while processing

**Auth error mapping:** matrix-nio exceptions → fast-fail categories:
- `LoginError`, `LocalProtocolError` with 401/403 → fast-fail (invalid token)
- `ConnectionError`, `TimeoutError` → reconnect (transient)

#### Phase 2: Config & Platform Registration

**Files to modify:**

`computer/parachute/connectors/config.py`:
- Add `MatrixConfig` Pydantic model
- Add `matrix: MatrixConfig` field to `BotsConfig`

`computer/parachute/api/bots.py`:
- Add `"matrix"` to all platform tuples: `("telegram", "discord", "matrix")`
- Add `MessengerConfigUpdate` → `MatrixConfigUpdate` model
- Add `elif platform == "matrix"` branch in `_start_platform()`
- Add Matrix test logic in `test_connector()` (call `client.whoami()`)
- Add Matrix section to `bots_config()` response
- Update `BotsConfigUpdate` with `matrix` field

`computer/parachute/models/session.py`:
- Add `MATRIX = "matrix"` to `SessionSource` enum

`computer/parachute/api/health.py`:
- Add `"matrix"` to health check platform loop

`computer/parachute/server.py`:
- No changes needed (shutdown loop iterates `_connectors` dict, platform-agnostic)

`computer/parachute/cli.py`:
- Add `"matrix"` to CLI bot command choices

#### Phase 3: Message Formatting

`computer/parachute/connectors/message_formatter.py`:
- Add `claude_to_matrix(text: str) -> tuple[str, str]` returning `(plain_body, html_body)`
- Convert Claude markdown to Matrix-safe HTML subset:
  - `**bold**` → `<b>bold</b>`
  - `*italic*` → `<i>italic</i>`
  - `` `code` `` → `<code>code</code>`
  - ````code blocks```` → `<pre><code>blocks</code></pre>`
  - `> blockquote` → `<blockquote>blockquote</blockquote>`
  - `- list items` → `<ul><li>items</li></ul>`
  - `[link](url)` → `<a href="url">link</a>`
  - `# heading` → `<h1>heading</h1>` (etc.)
  - Headings, tables → best-effort HTML conversion

#### Phase 4: Flutter App (Lightweight)

`app/lib/features/settings/widgets/bot_connectors_section.dart`:
- Add Matrix section with: homeserver URL, user ID (display only), access token, allowed rooms list, trust levels
- Reuse existing platform section pattern

### Dependency

One new Python dependency:
```
matrix-nio[e2e]>=0.25.0
```

The `[e2e]` extra is optional (includes crypto libs for future E2EE support) but harmless to install now. Core functionality works without it.

Note: `matrix-nio` is an optional dependency, guarded by `MATRIX_AVAILABLE` flag (same pattern as `TELEGRAM_AVAILABLE` and `DISCORD_AVAILABLE`).

## Acceptance Criteria

### Functional Requirements

- [x] `MatrixConnector` subclasses `BotConnector` and implements all abstract methods
- [x] Bot can connect to a Matrix homeserver using access token
- [x] Bot auto-joins rooms listed in `allowed_rooms`
- [x] Bot responds to mentions in group rooms (`mention_only` mode)
- [x] Bot responds to all messages in DMs
- [x] Bot responds to all messages in rooms with `all_messages` mode
- [x] Messages from Claude are formatted as Matrix HTML
- [x] Long messages are split at ~25K character boundaries
- [x] `!new`, `!help`, `!journal` commands work
- [x] Typing indicator shown while processing
- [x] Ack reaction added on message receipt, removed after response
- [x] Voice/audio messages are downloaded and transcribed
- [ ] Sync token persisted — restarts don't reprocess old messages
- [x] Backfilled messages on initial sync are ignored
- [x] DMs from unknown users trigger pairing workflow
- [x] Invites to non-allowed rooms create pending notification
- [x] `bots.yaml` supports `matrix:` section with all config fields
- [x] `/api/bots/status` includes Matrix connector status
- [x] `/api/bots/matrix/start`, `/stop`, `/test` endpoints work
- [x] `/api/bots/config` GET/PUT includes Matrix
- [x] CLI `parachute bot status/start/stop/config` supports matrix
- [x] Flutter settings UI shows Matrix section
- [x] Bridged users (mautrix puppets) can interact with the bot normally

### Non-Functional Requirements

- [x] Optional dependency: server starts fine without matrix-nio installed
- [x] Auth errors fast-fail (no retry on invalid token)
- [x] Transient errors trigger reconnection with exponential backoff
- [x] Display names sanitized before prompt injection
- [x] Access token never logged or exposed via API

### Testing

- [x] Config parsing: `MatrixConfig` model validation
- [x] Message formatting: `claude_to_matrix()` conversion tests
- [x] Message splitting at 25K boundary
- [x] Connector import test (importability, `MATRIX_AVAILABLE` flag)
- [ ] Reconnection behavior (reuse `_make_test_connector` pattern)

## Known Limitations (v1)

1. **No E2EE support** — Bot only works in unencrypted rooms. Logs a warning when invited to encrypted rooms. Many bridged rooms are unencrypted by default.
2. **No streaming responses** — Sends one final message (like Discord), no progressive editing.
3. **No room upgrade handling** — If a room is upgraded to a new version, the bot needs to be re-invited.
4. **matrix-nio maintenance** — The library works but hasn't had a release in 12+ months. Monitor for alternatives.

## Dependencies & Risks

| Risk | Mitigation |
|------|------------|
| matrix-nio maintenance stalled | Library is functional and stable; API surface is small enough to fork if needed |
| E2EE rooms are common | Document limitation clearly; most bridged rooms are unencrypted |
| Homeserver infrastructure required | User's responsibility; document setup for Conduit (lightweight) and Synapse |
| Rate limiting by homeserver | Self-hosted servers can exempt bot accounts; implement backoff on 429 |

## References

### Internal
- Base class: `computer/parachute/connectors/base.py`
- Telegram connector: `computer/parachute/connectors/telegram.py`
- Discord connector: `computer/parachute/connectors/discord_bot.py`
- Config system: `computer/parachute/connectors/config.py`
- Bots API: `computer/parachute/api/bots.py`
- Message formatter: `computer/parachute/connectors/message_formatter.py`
- Session models: `computer/parachute/models/session.py`
- Tests: `computer/tests/unit/test_bot_connectors.py`
- Brainstorm: `docs/brainstorms/2026-02-19-facebook-messenger-connector-brainstorm.md`

### External
- [matrix-nio documentation](https://matrix-nio.readthedocs.io/en/latest/)
- [Matrix Client-Server API spec](https://spec.matrix.org/v1.8/client-server-api/)
- [mautrix bridges (meta, telegram, discord, signal)](https://github.com/mautrix)
- [Matrix HTML subset spec](https://spec.matrix.org/v1.8/client-server-api/#mroommessage-msgtypes)

## Setup Notes (for docs)

### Quick Start: Conduit Homeserver (Development)

```bash
# Download Conduit (single binary, ~10MB)
# Create config, start server
# Register bot account
# Get access token via login API
```

### Quick Start: Public Homeserver (No Self-Hosting)

```bash
# Register bot account on matrix.org (or any public server)
# Get access token via Element or login API
# Configure in bots.yaml
```

### Bridging (Optional, User's Responsibility)

To let Messenger/Signal users join Matrix rooms:
1. Set up mautrix-meta / mautrix-signal on the homeserver
2. Bridge the room to the external platform
3. External users see and interact with the bot naturally
