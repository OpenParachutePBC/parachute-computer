---
title: "feat: Bridge-aware Matrix connector UX"
type: feat
date: 2026-02-20
issue: 85
---

# feat: Bridge-aware Matrix connector UX

## Overview

When a mautrix bridge creates a new portal room (Facebook Messenger, Instagram, etc.), the Parachute Matrix bot should auto-join, detect it's a bridged room, and initiate the pairing approval flow — the same UX as when a new user DMs the Telegram or Discord bot. After approval, the bot should auto-configure the room (add to `allowed_rooms`, set response mode, enable relay).

Today this requires 5 manual steps per conversation. This plan eliminates all of them.

## Problem Statement

Setting up Facebook Messenger bridging via mautrix-meta required:
1. Accept room invite as admin user
2. Invite `@parachute:localhost` to the bridged room
3. Bot joins but room isn't in `allowed_rooms` — messages ignored
4. Manually edit `bots.yaml` to add room ID
5. Restart the connector

Additionally, bridged DMs are misclassified as groups (ghost users inflate member count), and bot responses aren't relayed back without manually enabling relay mode.

## Proposed Solution

Extend the Matrix connector's invite and message handling to detect bridge rooms, create pairing requests for them, and auto-configure on approval. Reuse the existing pairing UI in the Flutter app — no app changes needed.

## Technical Approach

### Phase 1: Bridge Detection & Auto-Join

Add bridge detection to `matrix_bot.py`:

**New method: `_detect_bridge_room()`**

After joining a room (in `_on_invite()`), inspect room members to detect bridge patterns:

```python
# matrix_bot.py — new method
BRIDGE_GHOST_PATTERNS = [
    re.compile(r"^@meta_\d+:.+$"),      # mautrix-meta (Facebook/Instagram)
    re.compile(r"^@telegram_\d+:.+$"),   # mautrix-telegram
    re.compile(r"^@discord_\d+:.+$"),    # mautrix-discord
    re.compile(r"^@signal_\d+:.+$"),     # mautrix-signal
]

BRIDGE_BOT_PATTERNS = [
    re.compile(r"^@(meta|telegram|discord|signal|whatsapp)bot:.+$"),
]

async def _detect_bridge_room(self, room_id: str) -> Optional[dict]:
    """Detect if a room is bridged by checking member patterns.

    Returns dict with bridge_type, ghost_users, remote_chat_type or None.
    """
```

Logic:
1. Get room members via `self._client.joined_members(room_id)`
2. Classify each member as: self, bridge_bot, ghost_user, or real_user
3. If ghost_users found → bridged room
4. If exactly 1 ghost user → bridged DM; 2+ → bridged group
5. Return `{"bridge_type": "meta", "ghost_users": [...], "remote_chat_type": "dm"|"group"}`

**Files:** `matrix_bot.py:166-188` (extend `_on_invite`)

### Phase 2: Pairing Request for Bridged Rooms

Extend `_on_invite()` to create pairing requests for detected bridge rooms:

```python
# matrix_bot.py — enhanced _on_invite
async def _on_invite(self, room: Any, event: Any) -> None:
    if event.state_key != self.user_id:
        return

    room_id = room.room_id

    if self._is_room_allowed(room_id):
        await self._client.join(room_id)
        return

    # Join the room first (needed to inspect members)
    await self._client.join(room_id)

    # Detect if bridged
    bridge_info = await self._detect_bridge_room(room_id)

    if bridge_info:
        # Get room display name for the pairing request
        room_name = await self._get_room_display_name(room_id)
        await self._handle_bridged_room(
            room_id, room_name, bridge_info
        )
    # else: non-bridged, non-allowed room — already joined, messages will be ignored
```

**New method: `_handle_bridged_room()`**

Create a pairing request using the existing `handle_unknown_user()` pattern but adapted for rooms:

```python
async def _handle_bridged_room(self, room_id, room_name, bridge_info):
    """Create pairing request for a bridged room."""
    db = getattr(self.server, "database", None)
    if not db:
        return

    # Check for existing pending request for this room
    existing = await db.get_pairing_request_for_user("matrix", room_id)
    if existing:
        return

    # Create pairing request (room_id as platform_user_id)
    request_id = str(uuid.uuid4())
    await db.create_pairing_request(
        id=request_id,
        platform="matrix",
        platform_user_id=room_id,
        platform_user_display=room_name,
        platform_chat_id=room_id,
    )

    # Create pending session
    chat_type = bridge_info["remote_chat_type"]
    session_id = str(uuid.uuid4())
    trust_level = await self.get_trust_level(chat_type)
    create_data = SessionCreate(
        id=session_id,
        title=f"{room_name} (Matrix Bridge)",
        module="chat",
        source="matrix",
        trust_level=trust_level,
        linked_bot_platform="matrix",
        linked_bot_chat_id=room_id,
        linked_bot_chat_type=chat_type,
        metadata={
            "linked_bot": { ... },
            "pending_approval": True,
            "pairing_request_id": request_id,
            "bridge_metadata": bridge_info,
        },
    )
    await db.create_session(create_data)

    # Send a notice in the room
    await self._send_room_message(
        room_id,
        "I've joined this bridged room. Waiting for approval in the Parachute app."
    )
```

**Files:** `matrix_bot.py` (new methods), reuses `base.py` patterns

### Phase 3: Approval Handler — Add Room to `allowed_rooms`

Extend the approval endpoint in `api/bots.py` to handle Matrix room-based pairing:

**Modify `_add_to_allowlist()`** (`bots.py:533-553`):

```python
async def _add_to_allowlist(platform: str, identifier: str, *, is_room: bool = False) -> None:
    """Persist a user or room addition to the platform's allowlist."""
    async with _config_lock:
        config = load_bots_config(_vault_path)
        platform_config = getattr(config, platform, None)
        if not platform_config:
            return

        if is_room and hasattr(platform_config, "allowed_rooms"):
            if identifier not in platform_config.allowed_rooms:
                platform_config.allowed_rooms.append(identifier)
        else:
            current_users = [str(u) for u in platform_config.allowed_users]
            if identifier not in current_users:
                typed_id = int(identifier) if platform == "telegram" else identifier
                platform_config.allowed_users.append(typed_id)

        _write_bots_config(config)
```

**Modify `approve_pairing()`** (`bots.py:450-498`):

```python
# In approve_pairing(), after DB updates:
if pr.platform == "matrix" and pr.platform_user_id.startswith("!"):
    # Room-based approval — add to allowed_rooms
    await _add_to_allowlist("matrix", pr.platform_user_id, is_room=True)

    # Update running connector's in-memory allowed_rooms
    connector = _connectors.get("matrix")
    if connector and hasattr(connector, "allowed_rooms"):
        if pr.platform_user_id not in connector.allowed_rooms:
            connector.allowed_rooms.append(pr.platform_user_id)
else:
    # User-based approval (Telegram/Discord)
    await _add_to_allowlist(pr.platform, pr.platform_user_id)
```

**Files:** `api/bots.py:450-553`

### Phase 4: Bridged DM Detection in Message Handler

Fix the member count logic in `on_text_message()` (`matrix_bot.py:200-202`):

```python
# Replace simple member_count logic with bridge-aware detection
member_count = getattr(room, "member_count", 0) or getattr(room, "joined_count", 0) or 2

# Check if this is a bridged room — filter ghost users for chat type
session = await db.get_session_by_bot_link("matrix", room_id) if db else None
bridge_meta = (session.metadata or {}).get("bridge_metadata") if session else None

if bridge_meta and bridge_meta.get("remote_chat_type") == "dm":
    chat_type = "dm"
elif member_count <= 2:
    chat_type = "dm"
else:
    chat_type = "group"
```

This uses the bridge metadata stored at pairing time rather than re-inspecting members on every message (cheaper, more reliable).

**Files:** `matrix_bot.py:200-202`

### Phase 5: Auto-Relay After Approval

After a bridged room is approved, auto-send `!meta set-relay` to enable response bridging:

```python
# In approve_pairing() or in a post-approval hook in matrix_bot.py:
if bridge_metadata and bridge_metadata.get("is_bridged"):
    # Send relay command as the admin user (via the bridge bot)
    await connector._send_room_message(
        room_id,
        "!meta set-relay"
    )
```

**Caveat:** The `!meta set-relay` command needs to come from the logged-in user (`@unforced:localhost`), not the bot. The bot can send it but the bridge will try to relay it. Alternative: use the Matrix admin API to send as the admin user, or document this as a manual step.

**Simpler approach:** Have the bot set relay via the bridge's provisioning API if available. If not, send a notice asking the admin to run `!meta set-relay` in the room.

**Files:** `matrix_bot.py` (new post-approval method), `api/bots.py` (trigger after approval)

## Acceptance Criteria

### Functional Requirements

- [x] Bot auto-joins rooms when invited by a recognized bridge bot (`@metabot:*`, `@telegrambot:*`, etc.)
- [x] Bot detects bridged rooms by inspecting member patterns (ghost users)
- [x] Bot creates pairing request for each new bridged room
- [x] Pairing request appears in Flutter app with room name (e.g., "Aaron G Neyer (Matrix Bridge)")
- [x] Approving a bridged room adds its ID to `allowed_rooms` in bots.yaml
- [x] Approving a bridged room updates the running connector's in-memory allowed list (no restart needed)
- [x] Bridged DMs (1 ghost user) are detected and treated as DMs (all_messages mode)
- [x] Bridged groups (2+ ghost users) are detected and use configured group_mention_mode
- [x] Bot sends relay setup notice after approval

### Testing Requirements

- [x] Unit test: `_detect_bridge_room()` with meta, telegram, discord ghost patterns
- [x] Unit test: `_detect_bridge_room()` returns None for non-bridged rooms
- [x] Unit test: Bridged DM detection (1 ghost = DM, 2+ ghosts = group)
- [x] Unit test: `_add_to_allowlist()` with `is_room=True` adds to `allowed_rooms`
- [x] Unit test: Approval of Matrix room-based pairing request adds room to config

## Dependencies & Risks

- **matrix-nio `joined_members()` API** — Must return member list including ghost users. May need the room to be synced first.
- **Bridge bot naming convention** — Assumes mautrix uses `@*bot:homeserver` pattern. May need to be configurable.
- **Relay mode** — Auto-relay requires either the admin user or bridge provisioning API. May need to be a documented manual step initially.
- **Conduit ghost user bug** — Conduit returns wrong error code (`M_UNKNOWN` instead of `M_FORBIDDEN`) for ghost user joins in groups. DMs work fine. This is a known Conduit issue, not something we can fix.

## References

- Matrix connector: `computer/parachute/connectors/matrix_bot.py`
- Base connector (pairing flow): `computer/parachute/connectors/base.py:291-353`
- Bots API (approval): `computer/parachute/api/bots.py:450-553`
- Config model: `computer/parachute/connectors/config.py:63-81`
- Session model: `computer/parachute/models/session.py:177-203`
- Brainstorm: `docs/brainstorms/2026-02-20-bridge-aware-matrix-connector-brainstorm.md`
- Matrix connector plan: `docs/plans/2026-02-19-feat-matrix-bot-connector-plan.md`
