# Bot Management Overhaul

**Date**: 2026-02-08
**Status**: Brainstorm complete, ready for planning

---

## What We're Building

A comprehensive bot management system that makes Telegram and Discord bots first-class citizens in Parachute. Bots auto-start with the server, new users appear as pending sessions in the Chat UI for approval, and the full lifecycle is manageable from both the app and the CLI.

**Target users**: Owner + community/team members messaging the bot on Telegram and Discord.

---

## Why This Approach

The current bot system has the right foundation (connectors, pairing requests, trust levels) but the UX is fragmented — bots don't auto-start, configuration is buried in Settings, user approval is a separate flow from chat, and there's a 422 bug blocking basic setup. OpenClaw's patterns show that the best bot UX treats incoming bot conversations like regular chat sessions with an approval gate.

---

## Key Decisions

### 1. Auto-start: bots start with the server by default

When the server starts, any bot with a valid token and `enabled: true` (the default when a token is present) starts automatically. No manual "start" button needed. Users can explicitly disable a bot to prevent auto-start.

**Implementation**: Server lifespan reads `bots.yaml`, starts enabled connectors with valid tokens. Add `auto_start` field (default: true) or just use `enabled` as the gate.

### 2. Pending sessions appear in Chat list

When an unknown user messages the bot on Telegram/Discord:
- A session is created with status `pending_approval`
- It appears in the Chat session list with a visual badge (platform icon + "pending" indicator)
- The owner taps it to see the first message and approve/deny
- Approving the session also approves the user (adds to allowlist)
- Denying removes the session

This replaces the separate "Pending Approval Requests" section in Settings with an inline flow that feels natural — new conversations just show up.

### 3. Multiple approval paths

- **Chat list approval** (primary): Tap pending session, approve inline
- **Pre-add users**: Enter user IDs in bot config before they message
- **CLI approval**: `parachute bot approve <request_id>` for headless setups
- **Pairing codes** (future): Could add OpenClaw-style time-limited codes later

### 4. Per-platform trust with per-user override

Platform-wide defaults:
- DM trust level (default: `vault`)
- Group trust level (default: `sandboxed`)

During approval, owner can override trust level for that specific user. Stored in the pairing request / user record.

### 5. Full CLI management

```
parachute bot status              # Show all bots, running state, connected users
parachute bot start telegram      # Start a specific bot
parachute bot stop telegram       # Stop a specific bot
parachute bot config              # Show bot configuration
parachute bot config set telegram.bot_token <token>
parachute bot config set telegram.enabled true
parachute bot approve <request_id>  # Approve pending user
parachute bot deny <request_id>     # Deny pending user
parachute bot users                 # List approved users across platforms
```

### 6. Settings UI simplified

Bot config in Settings becomes:
- Per-platform: token input, enabled toggle, trust level defaults
- Test connection button
- Link to "View pending requests in Chat"

The heavy lifting (approval, session management) moves to the Chat list.

### 7. Bot sessions visible in Chat with platform context

Bot-linked sessions show:
- Platform icon (Telegram/Discord) in the session list
- User's display name from the platform
- Chat type indicator (DM vs group)
- Trust level badge

---

## OpenClaw Patterns Worth Adopting

| Pattern | OpenClaw | Parachute Adaptation |
|---------|----------|---------------------|
| Auto-start with daemon | Channels start when token present | Same — `enabled` + valid token = auto-start |
| Session key routing | `agent:{id}:{channel}:{scope}:{peer}` | Already have `linked_bot_platform` + `linked_bot_chat_id` |
| DM pairing modes | pairing / allowlist / open / disabled | Current pairing flow + pre-add + future codes |
| Layered trust | owner > agent > allowlisted > stranger | full > vault > sandboxed + per-user override |
| In-chat admin | `/activation`, `/status`, `/reset` | Could add bot commands later |
| Identity linking | Same person across platforms | Future — link Telegram + Discord user to same identity |

**Not adopting (YAGNI)**:
- Multi-agent routing / bindings (we have one server, one agent)
- Multi-account per platform
- Cross-channel session continuity
- Gateway RPC / WebSocket control plane

---

## Bug to Fix: 422 on Bot Config Save

The Settings UI sends a PUT to `/api/bots/config` with the token and allowed user IDs. Getting a 422 (Unprocessable Entity) — likely a Pydantic validation error. Need to check:
- Are `allowed_users` being sent as strings vs integers?
- Is the request body shape matching `BotsConfigUpdate`?
- Is the token field being sent as empty string when unchanged?

This is a blocking bug — fix first before any new features.

---

## Open Questions

1. **Group chat sessions**: When the bot is in a Telegram group, does each group get one session or one per user? (Current: one per chat_id, which means one per group)
2. **Session archival**: Should denied sessions be archived or deleted?
3. **Notification**: Should the app notify the owner when a new pairing request arrives? (Push notification or just badge in chat list?)
4. **Rate limiting**: For community access, should there be rate limits per user?

---

## Implementation Order (suggested)

1. Fix 422 bug (unblocks everything)
2. Auto-start bots on server startup
3. Pending sessions in Chat list with approval
4. CLI bot management commands
5. Settings UI cleanup
6. Per-user trust override on approval
