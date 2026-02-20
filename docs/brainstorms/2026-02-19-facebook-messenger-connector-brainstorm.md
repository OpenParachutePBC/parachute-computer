# Matrix Bot Connector

> Brainstorm — 2026-02-19 (pivoted from Facebook Messenger)

**Issue:** #76

## Origin: Facebook Messenger

The original idea was a Facebook Messenger bot connector for group philosophical dialogue. Research during planning revealed that **Meta's Messenger Platform API does not support bots in group chats** (briefly available in 2017, discontinued). This was the primary use case, so we pivoted.

## What We're Building

A Matrix protocol bot connector for Parachute, following the existing Telegram/Discord connector pattern. The bot joins Matrix rooms as a regular Matrix user and participates in group conversations — a philosophical companion that hangs out with people and can be shaped via its Parachute workspace.

Matrix is added **alongside** existing Telegram/Discord connectors, not replacing them. Users on other platforms (Messenger, Signal, WhatsApp) can participate via mautrix bridges set up on the Matrix homeserver side — that bridging infrastructure is outside Parachute's scope.

## Why Matrix

- **Group chat bots are first-class** — the primary use case works natively
- **Open, federated protocol** — aligns with Parachute's interoperability principles
- **mautrix bridges** connect Messenger, Signal, WhatsApp, Telegram, Discord users into Matrix rooms
- **Active Python SDK** — matrix-nio (v0.25.2) with async support
- **Beeper proved the architecture** — Matrix as universal messaging hub works at consumer scale
- **Bot appears as a regular room participant** — natural for the philosophical companion use case

## Why Not Messenger Directly

- Meta's Messenger Platform API is **DM-only** for bots — no group chat support
- Every Python Messenger SDK is dead or sync-only
- The "philosophical group dialogue" use case is impossible on the platform

## Why Not Matrix as Universal Hub (Replacing Native Connectors)

We considered having Matrix replace all native connectors (one Matrix bot + bridges to everything). We chose **not** to because:

- **Latency** — 2-4x more hops per message through bridges
- **Feature loss** — Telegram inline keyboards, Discord slash commands don't cross bridges
- **Infrastructure overhead** — running homeserver + bridges is real operational complexity
- **Working code** — Telegram/Discord connectors exist and work well

Matrix is added as a **peer connector**, not a replacement. The "hub" architecture can be revisited if maintaining native connectors becomes painful.

## Key Decisions

- **matrix-nio SDK** — async Python, no external bot framework
- **`sync_forever()` transport** — similar to Telegram's polling pattern
- **Hybrid auth model** — room-level trust for groups (anyone in an allowed room can talk), user-level pairing for DMs
- **No E2EE in v1** — significant complexity, most bridged rooms are unencrypted anyway
- **One final message** (like Discord) — no progressive edit streaming
- **`!command` prefix** for bot commands (`!new`, `!help`, `!journal`)
- **Sync token persistence** — SqliteStore in `vault/.parachute/matrix/` for fast restarts

## Scope

### In Scope
- `matrix_bot.py` connector subclassing `BotConnector`
- matrix-nio async SDK integration with `sync_forever()` loop
- `MatrixConfig` in connector config (`homeserver_url`, `user_id`, `access_token`, `allowed_rooms`, trust levels)
- Room invite handling (auto-join allowed rooms, pending notification for others)
- Group chat: mention gating (`m.mentions` + display name fallback), group history context
- DM support with existing pairing/approval workflow
- Message formatting (Claude markdown → Matrix HTML)
- Message splitting at ~25K character boundary
- Typing indicators, ack reactions
- Voice/audio message transcription (download from homeserver content repo)
- `bots.yaml` matrix section, API endpoints, CLI support, Flutter settings UI
- Setup documentation for homeserver + bot account

### Out of Scope (for now)
- E2EE (encrypted room support)
- Streaming/progressive edit responses
- Room upgrade handling
- mautrix bridge setup (user's responsibility)
- Replacing native Telegram/Discord connectors

## Open Questions (Resolved)

1. ~~Messenger group chat permissions~~ → **Answered: not supported. Pivoted to Matrix.**
2. ~~Message character limit~~ → **Matrix: 65KB event, ~25K safe text limit.**
3. **Webhook URL lifecycle** → **N/A for Matrix. Uses sync loop, not webhooks.**
4. ~~Rate limits~~ → **Matrix: configurable per-homeserver, can exempt bot accounts.**
5. ~~Page vs. User identity~~ → **Matrix: bot is a regular user with configurable display name/avatar.**

## References

- [matrix-nio documentation](https://matrix-nio.readthedocs.io/en/latest/)
- [Matrix Client-Server API spec](https://spec.matrix.org/v1.8/client-server-api/)
- [mautrix bridges](https://github.com/mautrix) — meta, telegram, discord, signal
- [Beeper](https://www.beeper.com/) — consumer proof of Matrix-as-hub architecture
- Existing connectors: `computer/parachute/connectors/telegram.py`, `computer/parachute/connectors/discord_bot.py`
- Base class: `computer/parachute/connectors/base.py`
- Config: `computer/parachute/connectors/config.py`
- Plan: `docs/plans/2026-02-19-feat-matrix-bot-connector-plan.md`
