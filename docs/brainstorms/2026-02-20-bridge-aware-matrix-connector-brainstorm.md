---
title: Bridge-Aware Matrix Connector UX
status: brainstorm
priority: P1
module: computer
tags: [matrix, bridge, bot-framework, ux]
issue: 85
---

# Bridge-Aware Matrix Connector UX

## What We're Building

When a mautrix bridge (Facebook Messenger, Instagram, etc.) creates a new portal room, the Parachute Matrix bot should automatically detect it, join, and initiate the pairing flow — just like when a new user DMs the Telegram or Discord bot. Today this requires manually inviting the bot, adding the room ID to `allowed_rooms` in bots.yaml, and restarting the connector.

### The Problem (Experienced Firsthand)

Setting up Facebook Messenger bridging via mautrix-meta required 5 manual steps per conversation:
1. Accept the room invite as admin user
2. Invite `@parachute:localhost` to the bridged room
3. Bot joins but room isn't in `allowed_rooms` — messages ignored
4. Manually edit `bots.yaml` to add room ID
5. Restart the connector

Additionally:
- Bridged DMs are misclassified as groups (ghost users inflate member count)
- Bot responses weren't bridged back until relay mode was manually enabled
- `group_mention_mode: mention_only` blocked responses in bridged rooms where mentioning isn't natural from the other platform

## Why This Approach

Use the existing pairing request flow (same as Telegram/Discord) for each new bridged room. This keeps the approval UX consistent across platforms — new rooms show up in the Parachute app for approval before the bot starts responding.

### Key Behaviors

1. **Auto-join on bridge invite**: When `@metabot:*` (or any recognized bridge bot) invites the Parachute bot to a room, auto-join it
2. **Detect bridged rooms**: Check room members for ghost user patterns (`@meta_*`, `@telegram_*`, `@discord_*`) to identify bridged rooms
3. **Detect bridged DMs vs groups**: A bridged DM has exactly 1 ghost user + bridge bot + our bot. Treat as DM regardless of member count
4. **Create pairing request**: Surface the new room in the app's pairing approval flow, showing the room name (which comes from the remote platform contact/group name)
5. **On approval**: Auto-add room to `allowed_rooms`, set appropriate response mode (all_messages for bridged DMs, mention_only for bridged groups), persist to bots.yaml
6. **Relay mode**: Auto-send `!meta set-relay` in rooms where the bot is approved (so responses flow back through the bridge)

### Scope

- Matrix connector changes only (`matrix_bot.py`)
- Config persistence changes (`config.py`, `api/bots.py`)
- No changes to Telegram/Discord connectors
- No changes to Flutter app (reuses existing pairing UI)

## Key Decisions

- **Pairing flow per room, not per bridge** — Consistent with existing platform behavior
- **Ghost user detection heuristic** — Match `@meta_*:`, `@telegram_*:`, `@discord_*:` patterns in room members
- **Bridged DM detection** — Count non-bot, non-bridge, non-self members; if exactly 1 ghost user, treat as DM
- **Auto-relay** — Bot should auto-send `!meta set-relay` after approval to enable response bridging

## Open Questions

- Should the bot auto-accept ALL invites or only from recognized bridge bots?
- How to handle room name changes (bridge updates room name when remote chat name changes)?
- Should there be a config option to disable bridge auto-detection for users who don't want it?
