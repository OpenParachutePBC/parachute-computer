---
title: "MCP System Cleanup & UI Improvements"
type: fix
date: 2026-03-23
issue: 329
---

# MCP System Cleanup & UI Improvements

Audit found bugs, missing UI features, and observability gaps in the MCP subsystem. This plan addresses them in four phases — bug fixes first, then UX improvements.

## Problem Statement

1. **Format mismatch bug**: `mcp.py` API and `mcp_loader.py` disagree on `.mcp.json` format. The API assumes flat format (servers as top-level keys) but the actual file uses `{ "mcpServers": { ... } }` wrapper. Adding/removing MCPs through the Flutter UI can corrupt the config.
2. **No env var management**: Can't set API tokens or env vars for MCPs from the UI. Must hand-edit JSON.
3. **Silent MCP failures**: When MCPs fail to start, warnings are transient SSE events with no persistent visibility.
4. **Stale configs**: Dead paths (`/Users/unforced/...`) silently fail validation.
5. **Secret exposure**: API returns plaintext tokens in `/api/mcps` responses.

## Phase 1: Fix the Config Format Bug

**Files**: `computer/parachute/api/mcp.py`

The root cause: `load_mcp_config()` blindly wraps the file content, and `save_mcp_config()` blindly unwraps. If the file has a `mcpServers` key (which it does), reads double-wrap and writes strip the wrapper inconsistently.

### Changes

**`load_mcp_config()`** — Detect format, normalize to internal `{ "mcpServers": { ... } }`:

```python
def load_mcp_config() -> dict[str, Any]:
    config_path = get_mcp_config_path()
    if not config_path.exists():
        return {"mcpServers": {}}
    try:
        raw = json.loads(config_path.read_text(encoding="utf-8"))
        # Handle both formats: wrapped { "mcpServers": {...} } and flat { "name": {...} }
        if "mcpServers" in raw and isinstance(raw["mcpServers"], dict):
            return raw  # Already wrapped
        return {"mcpServers": raw}  # Flat format, wrap it
    except Exception as e:
        logger.error(f"Error loading MCP config: {e}")
        return {"mcpServers": {}}
```

**`save_mcp_config()`** — Always write in `mcpServers`-wrapped format (matches what Claude Code and `mcp_loader.py` expect):

```python
def save_mcp_config(config: dict[str, Any]) -> None:
    config_path = get_mcp_config_path()
    # Always save in wrapped format for compatibility with mcp_loader.py
    if "mcpServers" in config:
        save_data = config
    else:
        save_data = {"mcpServers": config}
    content = json.dumps(save_data, indent=2)
    # ... atomic write (unchanged)
```

### Acceptance Criteria
- [ ] `load_mcp_config()` handles both wrapped and flat formats
- [ ] `save_mcp_config()` always writes wrapped format
- [ ] Adding an MCP via API, then reading via `mcp_loader.py`, returns the correct server
- [ ] Removing an MCP via API doesn't corrupt other entries

## Phase 2: Env Var Support in UI

**Files**: `computer/parachute/api/mcp.py`, `app/.../capabilities_screen.dart`, `app/.../mcp_server_info.dart`

### Server Changes

The `POST /api/mcps` endpoint already accepts arbitrary config dicts. The `env` field works — it's just not exposed in the UI. No server changes needed beyond ensuring the existing response includes the `env` dict.

Ensure `GET /api/mcps` response includes `env` keys (minus secret values — see Phase 4).

### Flutter Changes

**`_AddMcpDialog`** — Add env var key-value editor:

- Below the command/args or URL fields, add an "Environment Variables" section
- Dynamic list of key-value `TextField` pairs with add/remove buttons
- Pre-populate common patterns: when user types "glif" as name, suggest `GLIF_API_TOKEN`
- On submit, include `env` dict in config: `{'command': '...', 'args': [...], 'env': {'KEY': 'val'}}`

**`McpDetailScreen`** — Show env vars (values masked):

- List env var names with masked values (`GLIF_API_TOKEN: glif_a6f•••••759e`)
- "Edit" button to modify env vars

**`McpServerInfo` model** — Add `env` field:

```dart
class McpServerInfo {
  // ... existing fields
  final Map<String, String>? env;
}
```

### Acceptance Criteria
- [ ] Can add an MCP with env vars from the Flutter UI
- [ ] Can view env var names (masked values) on detail screen
- [ ] Can edit env vars on existing MCPs
- [ ] Env vars persist through add → list → detail round-trip

## Phase 3: MCP Status Visibility

**Files**: `computer/parachute/api/mcp.py`, `app/.../capabilities_screen.dart`, `app/.../mcp_providers.dart`

### Server: Batch Health Check Endpoint

Add `GET /api/mcps/status` — returns quick health check for all configured MCPs:

```json
{
  "servers": {
    "parachute": {"status": "ok", "tools_count": 12},
    "glif": {"status": "error", "error": "npx: command not found"},
    "browser": {"status": "ok", "tools_count": 47}
  }
}
```

Implementation: Run validation + optional quick connectivity test (with short timeout, e.g. 3s) for each server in parallel.

### Flutter: Status Indicators

**`_McpServerCard`** — Add status dot (green/red/grey):
- Green: last test passed
- Red: validation errors or last test failed
- Grey: never tested

**`_McpServersTab`** — Add "Check All" button in app bar that calls `/api/mcps/status`

**Provider**: `mcpStatusProvider` — caches last known status, refreshed on tab open and manual check.

### Session Warnings

**`ChatMessageBubble` or session header** — When MCP warnings arrive via SSE, display a persistent banner:

```
⚠ 2 MCP servers skipped: glif (npx not found), suno (path not found)
[Dismiss] [Open Settings]
```

Currently warnings are `WarningEvent` SSE messages. The Flutter client needs to catch `ErrorCode.mcpConnectionFailed` and display it prominently rather than as a transient notification.

### Acceptance Criteria
- [ ] Status endpoint returns health for all MCPs
- [ ] MCP cards show colored status indicator
- [ ] "Check All" button works
- [ ] MCP warnings in chat are visible as persistent banner (not just a flash)

## Phase 4: Secret Masking & Cleanup

### Mask Secrets in API Responses

**`GET /api/mcps`** — Mask values in `env` and `headers` dicts that look like secrets:

```python
MASK_PATTERNS = ['token', 'key', 'secret', 'password', 'authorization', 'bearer']

def mask_value(key: str, value: str) -> str:
    if any(p in key.lower() for p in MASK_PATTERNS):
        return value[:6] + "•••" + value[-4:] if len(value) > 14 else "•••"
    return value
```

Return full values only on `GET /api/mcps/{name}` with a `?reveal=true` query param (for the edit flow).

### Clean Up Stale Configs

Add a `GET /api/mcps/validate` endpoint that checks all stdio MCPs for:
- Command exists on PATH
- Args reference files that exist
- Returns list of issues

Flutter can call this on settings screen open and show a cleanup prompt.

### Acceptance Criteria
- [ ] API list response masks secret-looking values
- [ ] Stale path MCPs are flagged in validation endpoint
- [ ] Detail screen can reveal full values for editing

## Technical Considerations

- **Cache invalidation**: `mcp_loader.py` caches parsed configs. The API already calls `invalidate_mcp_cache()` after writes — verify this works after format fix.
- **Backward compat**: Both Claude Code (wrapped format) and older flat configs must continue to load. The loader already handles this; the API needs to match.
- **Trust levels**: Env var editor should NOT allow editing the `trust_level` field inline — that's a separate concern. Don't mix.
- **npx latency**: Out of scope for this issue. Could pin versions in a follow-up.

## Dependencies & Risks

- Phase 1 is a bug fix with no dependencies — can ship immediately
- Phase 2 requires Flutter UI work — moderate effort
- Phase 3 requires coordinated server + client changes
- Phase 4 is optional polish, low risk

## References

- `computer/parachute/api/mcp.py` — API endpoints (format bug here)
- `computer/parachute/lib/mcp_loader.py` — Config loader (correct format handling)
- `computer/parachute/core/orchestrator.py:881-1010` — `_discover_capabilities()` MCP resolution
- `computer/parachute/core/capability_filter.py` — Trust level filtering
- `app/lib/features/settings/screens/capabilities_screen.dart` — Flutter MCP UI
- `app/lib/features/settings/screens/capability_detail_screen.dart` — MCP detail view
- `app/lib/features/chat/models/mcp_server_info.dart` — Flutter MCP model
