---
title: "feat: Bot Management Overhaul"
type: feat
date: 2026-02-08
---

# Bot Management Overhaul

## Overview

Make bots first-class in Parachute: auto-start with server, pending bot conversations appear in Chat for approval, full CLI management, and per-user trust overrides. Fix the 422 bug blocking basic setup.

Brainstorm: `docs/brainstorms/2026-02-08-bot-management-brainstorm.md`

## Problem Statement

The bot system has the right foundation but the UX is fragmented:
- Bots don't auto-start — every server restart requires manual start via UI
- User approval is buried in Settings, disconnected from the Chat experience
- The 422 bug blocks saving Telegram config entirely
- Per-user trust levels are stored during approval but never enforced
- No CLI management — headless servers require raw HTTP calls
- Config saves don't affect running connectors
- No crash recovery — transient API outages permanently kill bots

## Proposed Solution

Six phases, each independently shippable:

1. Fix 422 bug (unblocks everything)
2. Auto-start bots on server startup
3. Pending sessions in Chat list with inline approval
4. CLI bot management commands
5. Settings UI cleanup + config-save restart
6. Per-user trust override enforcement

---

## Technical Approach

### Phase 1: Fix 422 Bug

**Root cause**: `PlatformConfigUpdate` in `api/bots.py` defines `allowed_users: Optional[list[str]]`, but `TelegramConfig` in `connectors/config.py` uses `list[int]`. The app sends integers (correct for Telegram), the API model coerces to strings, then merging into `TelegramConfig` causes type confusion.

**Fix**: Split the generic `PlatformConfigUpdate` into platform-specific models, or use `list[int | str]` with a validator.

#### `computer/parachute/api/bots.py`

```python
# Replace single PlatformConfigUpdate with platform-aware typing
class TelegramConfigUpdate(BaseModel):
    enabled: Optional[bool] = None
    bot_token: Optional[str] = None
    allowed_users: Optional[list[int]] = None       # int for Telegram
    dm_trust_level: Optional[TrustLevelStr] = None
    group_trust_level: Optional[TrustLevelStr] = None

class DiscordConfigUpdate(BaseModel):
    enabled: Optional[bool] = None
    bot_token: Optional[str] = None
    allowed_users: Optional[list[str]] = None        # str for Discord
    allowed_guilds: Optional[list[str]] = None
    dm_trust_level: Optional[TrustLevelStr] = None
    group_trust_level: Optional[TrustLevelStr] = None

class BotsConfigUpdate(BaseModel):
    telegram: Optional[TelegramConfigUpdate] = None
    discord: Optional[DiscordConfigUpdate] = None
```

**Acceptance criteria**:
- [x] PUT `/api/bots/config` with `allowed_users: [123456]` (int) succeeds for Telegram
- [x] PUT `/api/bots/config` with `allowed_users: ["987654321"]` (str) succeeds for Discord
- [x] App Settings can save Telegram config with token + user IDs without 422
- [x] Existing `bots.yaml` with mixed types loads correctly

---

### Phase 2: Auto-Start Bots on Server Startup

**Where**: `server.py` lifespan, after `init_bots_api()` call (~line 138).

**Logic**:
1. Load `bots.yaml` via `load_bots_config(vault_path)`
2. For each platform: if `enabled` and `bot_token` is non-empty, start connector
3. Handle failures gracefully — log error, continue to next platform
4. Don't crash the server if a bot fails to start

#### `computer/parachute/server.py` (lifespan addition)

```python
# After init_bots_api(vault_path, server_ref)
from parachute.connectors.config import load_bots_config
from parachute.api.bots import auto_start_connectors

bots_config = load_bots_config(vault_path)
await auto_start_connectors(bots_config)
```

#### `computer/parachute/api/bots.py` (new function)

```python
async def auto_start_connectors(bots_config: BotsConfig) -> None:
    """Start enabled connectors with valid tokens. Errors are logged, not raised."""
    for platform in ["telegram", "discord"]:
        cfg = getattr(bots_config, platform)
        if cfg.enabled and cfg.bot_token:
            try:
                await _start_connector(platform)
                logger.info(f"Auto-started {platform} connector")
            except Exception as e:
                logger.error(f"Failed to auto-start {platform}: {e}")
```

**Design decision**: No separate `auto_start` flag — `enabled` + valid token = auto-start. If owner stops a bot via API, it restarts on next server boot. This is the simplest model and matches OpenClaw's behavior. If users need "configured but not running," they set `enabled: false`.

**Acceptance criteria**:
- [x] Server starts with Telegram enabled + valid token → Telegram connector running
- [x] Server starts with invalid token → logs error, server continues, other bots unaffected
- [x] Server starts with `enabled: false` → connector not started
- [x] `parachute server status` or health endpoint reflects bot connector state

---

### Phase 3: Pending Sessions in Chat List

This is the biggest UX change. When an unknown user messages the bot, instead of only creating a `PairingRequest`, we also create a session that appears in the Chat list with a "pending approval" indicator.

#### 3a. Server: Create session on pairing request

Currently `handle_unknown_user()` creates a `PairingRequest` but no session. Change to:

#### `computer/parachute/connectors/base.py`

```python
async def handle_unknown_user(self, platform, user_id, user_display, chat_id, chat_type, message_text=None):
    """Handle message from unknown user: create pairing request + pending session."""
    existing = await self.db.get_pairing_request_for_user(platform, str(user_id))
    if existing and existing.status == "pending":
        return "Your request is still pending approval."

    # Create pairing request
    request_id = str(uuid4())
    await self.db.create_pairing_request(
        id=request_id, platform=platform,
        platform_user_id=str(user_id),
        platform_chat_id=str(chat_id),
        platform_user_display=user_display,
    )

    # Create a pending session linked to this request
    session = await self.db.create_session(SessionCreate(
        source=SessionSource(platform),
        title=f"{user_display} ({platform})",
        linked_bot_platform=platform,
        linked_bot_chat_id=str(chat_id),
        linked_bot_chat_type=chat_type,
        trust_level=self.get_trust_level(chat_type),
        metadata={
            "pairing_request_id": request_id,
            "pending_approval": True,
            "first_message": message_text,
        },
    ))

    return "Hi! I need approval from the owner before we can chat. Your request has been sent."
```

#### 3b. Server: Session list includes pending indicator

Add `pending_approval` to the session list response. The `metadata.pending_approval` flag is already set; the app just needs to read it.

#### 3c. Server: Approval activates the session

When owner approves via `POST /api/bots/pairing/{id}/approve`:
- Mark pairing request as approved
- Clear `metadata.pending_approval` on the linked session
- Add user to allowlist
- Send approval message on platform

#### 3d. Server: Denial removes the session

When owner denies:
- Mark pairing request as denied
- Archive or delete the linked session
- Send denial message to user on platform (new: currently no denial notification)

#### 3e. App: Chat list shows pending sessions

#### `app/lib/features/chat/widgets/session_list_item.dart`

```dart
// In the session list item, check for pending approval
if (session.metadata?['pending_approval'] == true) {
  // Show platform icon + "Pending Approval" badge
  // Show first message preview
  // Tap → approval dialog (approve/deny with trust level picker)
}
```

The approval dialog should:
- Show user's display name and platform
- Show the first message they sent
- Trust level picker (default from platform config)
- Approve / Deny buttons
- On approve: `POST /api/bots/pairing/{id}/approve`
- On deny: `POST /api/bots/pairing/{id}/deny`

#### `app/lib/features/chat/models/chat_session.dart`

```dart
// Add to ChatSession
bool get isPendingApproval => metadata?['pending_approval'] == true;
String? get pairingRequestId => metadata?['pairing_request_id'];
String? get firstMessage => metadata?['first_message'];
```

**Acceptance criteria**:
- [x] Unknown user messages Telegram bot → session appears in Chat list with "pending" badge
- [x] Tapping pending session shows first message + approve/deny UI
- [x] Approving: session becomes active, user added to allowlist, user gets welcome message
- [x] Denying: session archived/removed, user gets denial message
- [x] Multiple messages before approval don't create duplicate sessions

---

### Phase 4: CLI Bot Management

Add `parachute bot` subcommand group. Follow existing patterns from `module` commands.

**Communication model**: Online-first (call server API), with offline fallback for status/config reads.

#### Commands

```
parachute bot status                          # Show all bots status
parachute bot start <platform>                # Start a connector
parachute bot stop <platform>                 # Stop a connector
parachute bot config                          # Show bot configuration
parachute bot config set <key> <value>        # Set a config value
parachute bot approve [request_id]            # Approve pending user (list if no ID)
parachute bot deny <request_id>               # Deny pending user
parachute bot users                           # List approved users
```

#### `computer/parachute/cli.py` (additions)

```python
def cmd_bot(args: argparse.Namespace) -> None:
    """Bot connector management."""
    action = getattr(args, "action", None)
    if action == "status":
        _bot_status()
    elif action == "start":
        _bot_start(args.platform)
    elif action == "stop":
        _bot_stop(args.platform)
    elif action == "config":
        sub = getattr(args, "config_action", None)
        if sub == "set":
            _bot_config_set(args.key, args.value)
        else:
            _bot_config_show()
    elif action == "approve":
        _bot_approve(getattr(args, "request_id", None))
    elif action == "deny":
        _bot_deny(args.request_id)
    elif action == "users":
        _bot_users()

def _bot_status():
    """Show bot connector status — tries server API, falls back to config file."""
    server_url = _get_server_url()
    try:
        status = _api_get(f"{server_url}/api/bots/status")
        for platform, info in status.items():
            running = info.get("running", False)
            enabled = info.get("enabled", False)
            has_token = info.get("has_token", False)
            state = "running" if running else ("enabled" if enabled else "disabled")
            print(f"  {platform}: {state}")
            if has_token:
                print(f"    token: configured")
            if running:
                users = info.get("connected_users", 0)
                print(f"    users: {users}")
    except Exception:
        # Offline fallback — read bots.yaml directly
        vault_path = _get_vault_path()
        config_path = vault_path / ".parachute" / "bots.yaml"
        if config_path.exists():
            # ... read and display
            pass
        else:
            print("No bot configuration found.")

def _bot_approve(request_id: Optional[str]):
    """Approve a pending pairing request. Lists pending if no ID given."""
    server_url = _get_server_url()
    if not request_id:
        # List pending requests
        requests = _api_get(f"{server_url}/api/bots/pairing")
        if not requests:
            print("No pending pairing requests.")
            return
        for r in requests:
            print(f"  [{r['id'][:8]}] {r['platform_user_display']} on {r['platform']}")
            print(f"           ID: {r['id']}")
        return
    # Approve specific request
    _api_post(f"{server_url}/api/bots/pairing/{request_id}/approve", {})
    print(f"Approved: {request_id}")
```

**Acceptance criteria**:
- [x] `parachute bot status` shows running/enabled/disabled for each platform
- [x] `parachute bot start telegram` starts the Telegram connector
- [x] `parachute bot approve` with no args lists pending requests
- [x] `parachute bot approve <id>` approves a specific request
- [x] `parachute bot config set telegram.bot_token <token>` updates bots.yaml
- [x] Commands work when server is running; status/config degrade gracefully when offline

---

### Phase 5: Settings UI Cleanup + Config-Save Restart

#### 5a. Server: Restart connector on config save

#### `computer/parachute/api/bots.py` (update_bots_config)

After writing the new config to YAML, check if any affected platform's connector is running and restart it:

```python
# At end of update_bots_config()
for platform in ["telegram", "discord"]:
    update = getattr(body, platform, None)
    if update and platform in _connectors:
        logger.info(f"Config changed for {platform}, restarting connector")
        await _stop_connector(platform)
        await _start_connector(platform)
```

#### 5b. Server: Add write lock for bots.yaml

```python
_config_lock = asyncio.Lock()

async def update_bots_config(...):
    async with _config_lock:
        # ... existing read-modify-write logic

async def _add_to_allowlist(...):
    async with _config_lock:
        # ... existing allowlist update logic
```

#### 5c. App: Simplify bot settings

The Settings UI becomes:
- Per-platform: token input, enabled toggle, default trust levels (DM + group)
- Test connection button
- Save button (saves + restarts running connector)
- Start/Stop button
- Note: "Pending requests appear in Chat"

Remove the pairing requests section from Settings (it moves to Chat list in Phase 3).

**Acceptance criteria**:
- [x] Saving config while connector is running auto-restarts it
- [x] Concurrent config saves and approvals don't corrupt bots.yaml
- [x] Pairing requests section removed from Settings (moved to Chat)
- [x] Settings shows simplified per-platform config

---

### Phase 6: Per-User Trust Override

#### 6a. Server: Look up per-user trust at message time

When a known user sends a message, check if they have an approved pairing request with a custom trust level.

#### `computer/parachute/connectors/base.py`

```python
def get_trust_level(self, chat_type: str, user_id: str = None) -> str:
    """Get trust level for a message context, with per-user override."""
    if user_id:
        # Check for per-user override from pairing approval
        request = await self.db.get_pairing_request_for_user(
            self.platform, str(user_id)
        )
        if request and request.status == "approved" and request.approved_trust_level:
            return request.approved_trust_level

    # Fall back to platform default
    if chat_type == "group":
        return self.config.group_trust_level
    return self.config.dm_trust_level
```

**Note**: This makes `get_trust_level` async (needs `await` for DB query). Alternative: cache approved users' trust levels in memory on connector start and update on approval.

#### 6b. App: Trust level picker in approval dialog

When approving a pending session in the Chat list, show a trust level dropdown defaulting to the platform's DM trust level.

**Acceptance criteria**:
- [x] Approving with "sandboxed" trust → user's sessions use sandboxed trust
- [x] Default trust level comes from platform config
- [x] Per-user trust persists across server restarts (stored in pairing_requests table)
- [x] Changing platform default doesn't affect previously-approved per-user overrides

---

## Implementation Order

```
Phase 1 (fix 422) ──→ Phase 2 (auto-start) ──→ Phase 5 (config restart)
                                               ↗
Phase 3 (pending sessions) ──→ Phase 6 (per-user trust)

Phase 4 (CLI) can run in parallel with Phase 3
```

**Suggested order**: 1 → 2 → 3 → 4 → 5 → 6

Phase 1 is ~30 minutes. Phase 2 is ~1 hour. Phases 3-6 are each a few hours.

---

## Files to Modify

### Computer (Python server)

| File | Changes |
|------|---------|
| `parachute/api/bots.py` | Split `PlatformConfigUpdate`, add auto-start, add config lock, restart on save |
| `parachute/connectors/base.py` | Create pending session on unknown user, per-user trust lookup |
| `parachute/connectors/config.py` | No changes needed |
| `parachute/server.py` | Call `auto_start_connectors()` in lifespan |
| `parachute/cli.py` | Add `bot` subcommand group |
| `parachute/db/database.py` | Add `get_session_by_pairing_request()`, update pending session on approval |

### App (Flutter)

| File | Changes |
|------|---------|
| `lib/features/chat/models/chat_session.dart` | Add `isPendingApproval`, `pairingRequestId`, `firstMessage` |
| `lib/features/chat/widgets/session_list_item.dart` | Show pending badge, platform icon |
| `lib/features/chat/screens/chat_hub_screen.dart` | Approval dialog on pending session tap |
| `lib/features/settings/widgets/bot_connectors_section.dart` | Simplify, remove pairing section |
| `lib/core/services/api_service.dart` | Add `approvePairing()`, `denyPairing()` if not present |

### Tests

| File | Changes |
|------|---------|
| `tests/unit/test_bot_connectors.py` | Fix existing failures, add auto-start tests |
| `tests/unit/test_cli_commands.py` | Add bot subcommand tests |
| `tests/integration/test_bots_api.py` | New: 422 fix verification, config save + restart |

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Auto-start delays server boot | Start connectors async, don't await completion |
| Connector crash loops on bad token | Log error once, don't retry with same config |
| Race condition on bots.yaml writes | asyncio.Lock around all writes |
| Pending sessions clutter Chat list | Auto-archive denied sessions, TTL on stale pending |
| Per-user trust DB lookup adds latency | Cache in connector memory, refresh on approval |

---

## References

- Brainstorm: `docs/brainstorms/2026-02-08-bot-management-brainstorm.md`
- OpenClaw patterns: auto-start, layered trust, pairing flow
- Existing code: `connectors/base.py`, `api/bots.py`, `connectors/config.py`
- CLI patterns: `cli.py` (module subcommands as template)
- App session list: `session_list_item.dart`, `chat_session.dart`
