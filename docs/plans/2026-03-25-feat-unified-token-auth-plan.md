---
title: "Unified token auth — one setup-token for sandbox and trusted sessions"
type: feat
date: 2026-03-25
issue: 349
---

# Unified Token Auth

Use one explicit `setup-token` everywhere — sandbox and trusted sessions alike. Fix the broken configuration paths so users can actually set the token.

## Problem

Sandbox sessions fail with missing `CLAUDE_CODE_OAUTH_TOKEN` because:
1. `parachute config set token` refuses with an error (line 1889 of `cli.py`)
2. `parachute install` is the only path and it's interactive/easy to skip
3. App settings has "Run claude login" which doesn't produce a `.token` file
4. No auth error feedback tells users what to do

## Acceptance Criteria

- [x] `parachute config set token <value>` writes `~/.parachute/.token`
- [x] `PUT /api/settings/token` saves token and hot-reloads it in the running server
- [x] `GET /api/settings/token` returns `{ configured: bool, prefix: "sk-ant-...abc" }` (never full token)
- [x] App settings shows token status (configured / not configured) and a paste flow
- [x] Auth failures emit `typed_error` with `EXPIRED_TOKEN` code and clear recovery message
- [x] `parachute doctor` token check tells user exactly how to fix (not just "run install")

## Implementation

### Step 1: Fix CLI `config set token` — `computer/parachute/cli.py`

**What**: Remove the guard at line 1889 that blocks `token` / `claude_code_oauth_token` keys.

**Change `_config_set()`**: When key is `token` or `claude_code_oauth_token`, call `save_token(parachute_dir, value)` instead of rejecting. Print masked confirmation.

```python
def _config_set(key: str, value: str) -> None:
    if key in ("token", "claude_code_oauth_token"):
        parachute_dir = _get_parachute_dir()
        save_token(parachute_dir, value)
        masked = value[:12] + "..." if len(value) > 12 else "***"
        print(f"Token saved to {parachute_dir / '.token'} ({masked})")
        print("Note: Restart the server for the new token to take effect.")
        return
    # ... rest unchanged
```

### Step 2: Token API endpoints — `computer/parachute/api/settings.py`

**What**: Add `GET /api/settings/token` and `PUT /api/settings/token`.

**GET** returns `{ "configured": true, "prefix": "sk-ant-sid01-...abc" }` — first 12 chars + last 3 chars, never the full token.

**PUT** accepts `{ "token": "..." }`:
1. Validates non-empty
2. Calls `save_token()` to write `~/.parachute/.token`
3. Hot-reloads: calls `get_settings()` to get the singleton, sets `settings.claude_code_oauth_token = token`
4. Updates `orchestrator._sandbox.claude_token` if sandbox exists
5. Returns `{ "ok": true, "configured": true }`

```python
class TokenUpdate(BaseModel):
    token: str

@router.get("/settings/token")
async def get_token_status(request: Request) -> dict:
    token = _load_token(PARACHUTE_DIR)
    if not token:
        return {"configured": False, "prefix": None}
    prefix = token[:12] + "..." + token[-3:] if len(token) > 15 else "***"
    return {"configured": True, "prefix": prefix}

@router.put("/settings/token")
async def save_token_endpoint(body: TokenUpdate, request: Request) -> dict:
    token = body.token.strip()
    if not token:
        raise HTTPException(status_code=400, detail="Token cannot be empty")
    save_token(PARACHUTE_DIR, token)
    # Hot-reload in running server
    settings = get_settings()
    settings.claude_code_oauth_token = token
    orchestrator = request.app.state.orchestrator
    if hasattr(orchestrator, '_sandbox'):
        orchestrator._sandbox.claude_token = token
    return {"ok": True, "configured": True}
```

### Step 3: App settings — `app/lib/features/settings/widgets/claude_auth_section.dart`

**What**: Replace "Run claude login" with a setup-token paste flow.

**UI design**:
- Status line: green check "Token configured (sk-ant-...abc)" or yellow warning "Token not configured"
- "Update Token" button → shows a paste dialog with:
  - Instructions: "Run `claude setup-token` in your terminal, then paste the token here"
  - TextField (obscured) for pasting
  - Save button → calls `PUT /api/settings/token`
  - Success/error feedback

**Data flow**:
- On widget init: `GET /api/settings/token` to check status
- On save: `PUT /api/settings/token` → refresh status
- Uses existing server connection from `ref.watch(serverConfigProvider)`

### Step 4: Auth error detection — `computer/parachute/lib/typed_errors.py`

**What**: Improve `EXPIRED_TOKEN` error definition to give specific recovery instructions.

Update the `EXPIRED_TOKEN` entry:
```python
ErrorCode.EXPIRED_TOKEN: {
    "title": "Token Expired or Invalid",
    "message": "Your Claude token has expired or is invalid. Run `claude setup-token` in your terminal and update it in Settings.",
    "actions": [
        RecoveryAction(key="s", label="Open Settings", action="settings"),
    ],
    "can_retry": False,
},
```

The existing `parse_error()` already detects 401/unauthorized/token/expired patterns and maps to `EXPIRED_TOKEN`. The typed error system already emits `typed_error` SSE events. The app already renders `ErrorRecoveryCard` for these. **No new wiring needed** — just better copy.

### Step 5: Doctor check improvement — `computer/parachute/cli.py`

**What**: Make the token check in `cmd_doctor` more actionable.

Current (line 1744-1750): Returns `"no token found (run: parachute install)"`.

Updated:
```python
def check_token():
    token = _load_token(parachute_dir) or os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    if token:
        return True, f"{token[:12]}..."
    return False, (
        "no token found\n"
        "      Fix: Run `claude setup-token` then `parachute config set token <value>`\n"
        "      Or: Paste in Settings > Claude Authentication"
    )
```

## Files Changed

| File | Change |
|------|--------|
| `computer/parachute/cli.py` | Fix `_config_set` guard, improve doctor token check |
| `computer/parachute/api/settings.py` | Add `GET/PUT /api/settings/token` endpoints |
| `computer/parachute/lib/typed_errors.py` | Better `EXPIRED_TOKEN` message copy |
| `app/lib/features/settings/widgets/claude_auth_section.dart` | Token paste flow + status |

## What's NOT Changing

- `claude_sdk.py` — already correctly passes `CLAUDE_CODE_OAUTH_TOKEN` to SDK env. No code change needed.
- `orchestrator.py` — already reads token from settings at stream time (`get_settings().claude_code_oauth_token`). Hot-reload in Step 2 makes it pick up the new value.
- `config.py` — `save_token()` and `_load_token()` already exist and work correctly.

## Risks

- **Hot-reload race**: If a stream is in-flight when the token is updated, that stream keeps the old token (captured at start). Acceptable — next stream gets the new token.
- **Token validation**: We don't validate the token format on save. Could add a basic prefix check (`sk-ant-` or `oauth-`) but not blocking — bad tokens will fail at SDK call time with a clear typed error.

## Test Plan

- [ ] `parachute config set token test-value` → writes `.token`, prints masked confirmation
- [ ] `curl localhost:3333/api/settings/token` → returns configured status
- [ ] `curl -X PUT localhost:3333/api/settings/token -d '{"token":"..."}' -H 'Content-Type: application/json'` → saves and hot-reloads
- [ ] App settings shows token status, paste flow works
- [ ] With invalid token, chat attempt shows "Token Expired or Invalid" error card with Settings action
- [ ] `parachute doctor` shows actionable fix when token is missing
