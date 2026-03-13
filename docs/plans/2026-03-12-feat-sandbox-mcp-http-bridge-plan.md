---
title: Sandbox MCP HTTP Bridge
type: feat
date: 2026-03-12
issue: 234
---

# Sandbox MCP HTTP Bridge

Build an HTTP MCP endpoint on the Parachute server so sandboxed containers can access host-side tools over the network instead of spawning stdio MCP subprocesses inside Docker.

## Problem Statement

Stdio MCP servers silently fail to connect inside Docker sandbox containers (#234). The CLI receives `--mcp-config` JSON but never registers the tools. This blocks callers, sandboxed chat sessions, and any future sandboxed agent from using MCP tools.

Rather than debug the stdio subprocess issue (unknown root cause, possibly in the CLI), we build a proper HTTP MCP bridge — the right architectural boundary between sandbox containers and host-side tools.

## Proposed Solution

A Streamable HTTP MCP endpoint at `/mcp/v1` on the existing FastAPI server. Sandbox containers connect via `http://host.docker.internal:3333/mcp/v1`. Session-scoped bearer tokens authenticate requests and carry permission context.

```
Container: Claude CLI → HTTP MCP client → http://host.docker.internal:3333/mcp/v1
Host:      FastAPI → auth middleware → MCP handler → tool dispatch → existing services
```

## Acceptance Criteria

- [x] Sandboxed agent can call MCP tools (read journal, search memory, write output)
- [ ] Existing daily callers work end-to-end (trigger → agent runs → card appears)
- [x] Each sandbox session gets its own scoped token with permission context
- [x] Write tools are gated — only sessions with explicit write permission can call them
- [x] No stdio MCP servers or scripts copied into containers
- [ ] Integration test: trigger a caller, verify card output

## Implementation Plan

### Step 1: Add `mcp` to dependencies

**File:** `computer/pyproject.toml`

`mcp` is currently a transitive dep of `claude-agent-sdk` (v1.26.0 installed) but not declared. Add it explicitly since we're importing from `mcp.server` and `mcp.types` directly.

```
"mcp>=1.6.0",
```

Note: `mcp` v1.6.0+ has `StreamableHTTPSessionManager`. We already have v1.26.0 installed.

### Step 2: Sandbox token system

**New file:** `computer/parachute/lib/sandbox_tokens.py` (~60 lines)

Simple in-memory token store mapping opaque tokens to session context. No JWT, no persistence — tokens live only as long as the server process.

```python
@dataclass
class SandboxTokenContext:
    session_id: str
    trust_level: str           # "sandboxed"
    agent_name: str | None     # For callers
    allowed_writes: list[str]  # Tool names this session may call (e.g. ["write_output"])
    created_at: datetime

class SandboxTokenStore:
    def create_token(self, ctx: SandboxTokenContext) -> str: ...
    def validate_token(self, token: str) -> SandboxTokenContext | None: ...
    def revoke_token(self, token: str) -> None: ...
```

- Token = `secrets.token_urlsafe(32)`
- Store = `dict[str, SandboxTokenContext]`
- Revoke on session end (cleanup, not security-critical)

### Step 3: HTTP MCP endpoint

**New file:** `computer/parachute/api/mcp_bridge.py` (~200 lines)

Mount the MCP `StreamableHTTPSessionManager` as an ASGI sub-app inside FastAPI. Use stateless mode + JSON responses (no SSE, no session state — each request is independent).

**Key pattern** (from MCP SDK examples):

```python
from mcp.server import Server
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager

mcp_server = Server("parachute-sandbox")
session_manager = StreamableHTTPSessionManager(
    app=mcp_server,
    event_store=None,
    json_response=True,
    stateless=True,
)
```

**Auth middleware:** Before the MCP handler processes a request, extract the `Authorization: Bearer <token>` header, validate against `SandboxTokenStore`, and inject the `SandboxTokenContext` into the request scope. Return 401 if invalid.

**Lifespan integration:** The session manager requires `async with session_manager.run()`. Integrate into the existing `lifespan()` in `server.py` using a nested context manager or by starting/stopping the session manager alongside existing services.

**Mount:** `app.mount("/mcp/v1", mcp_asgi_handler)` — registered in `server.py` lifespan after `SandboxTokenStore` is initialized.

### Step 4: MCP tool handlers

**New file:** `computer/parachute/api/mcp_tools.py` (~150 lines)

Register tool handlers on the MCP `Server` instance. Each tool calls existing internal services (daily module endpoints, brain service, session store) — no new business logic needed.

**Read tools** (available to all sandbox sessions):

| Tool | Description | Calls |
|------|-------------|-------|
| `read_journal` | Read a journal entry by date | `GET /api/daily/entries?date=` |
| `read_recent_journals` | Read last N days of journals | `GET /api/daily/entries` with date range |
| `search_memory` | Search across all memory | Brain service `search_memory()` |
| `list_recent_sessions` | List recent chat sessions | Session store `list_sessions()` |
| `read_brain_entity` | Read a brain graph entity | Brain service cypher query |

**Write tools** (gated by `allowed_writes` in token context):

| Tool | Description | Calls |
|------|-------------|-------|
| `write_output` | Write agent output card | `POST /api/daily/cards/write` |

Tool handlers get the `SandboxTokenContext` from the request scope to check write permissions and inject the agent name / session context.

**Important:** Tools call internal Python services directly (not HTTP loopback). The daily module, brain service, and session store are accessible via `app.state` or the service registry.

### Step 5: Wire sandbox configs to use HTTP MCP

**File:** `computer/parachute/core/daily_agent.py`

Replace `_build_daily_tools_mcp_config()` (stdio, lines 275-285) and `load_vault_mcps()` (lines 181-196) with HTTP MCP config builder:

```python
def _build_http_mcp_config(token: str) -> dict[str, Any]:
    return {
        "type": "http",
        "url": "http://host.docker.internal:3333/mcp/v1",
        "headers": {"Authorization": f"Bearer {token}"},
    }
```

In `_run_sandboxed()`:
1. Create a sandbox token via `SandboxTokenStore.create_token()` with `allowed_writes=["write_output"]`
2. Build HTTP MCP config with the token
3. Pass as the sole MCP server in `AgentSandboxConfig.mcp_servers`
4. Revoke token after the sandbox run completes (in finally block)

**File:** `computer/parachute/core/sandbox.py`

No changes needed — sandbox already passes `mcp_servers` dict through to capabilities JSON.

**File:** `computer/parachute/docker/entrypoint.py`

No changes needed — line 269-270 already passes `capabilities["mcp_servers"]` to `ClaudeAgentOptions`. HTTP configs flow through as-is.

### Step 6: Clean up stdio MCP artifacts

- Remove `_build_daily_tools_mcp_config()` from `daily_agent.py`
- Remove `load_vault_mcps()` and `filter_stdio_servers()` import from `daily_agent.py`
- Keep `computer/parachute/docker/daily_tools_mcp.py` for now (reference, delete in follow-up)
- Update `filter_stdio_servers()` docstring in `mcp_loader.py` (it claims SDK doesn't support HTTP — outdated)

### Step 7: Integration test

**New file:** `computer/tests/test_mcp_bridge.py` (~80 lines)

- Test token creation/validation/revocation
- Test MCP `initialize` → `tools/list` → `tools/call` flow via HTTP client
- Test write permission gating (unauthorized write returns error)
- Test invalid/expired token returns 401

## Technical Considerations

### Auth: Opaque tokens, not JWT

JWT is overkill — tokens are validated on the same server that issued them. An opaque `secrets.token_urlsafe(32)` mapped to context in a dict is simpler and revocable. PyJWT is already a dependency if we want it later.

### Stateless MCP: No session management

Each POST to `/mcp/v1` creates a fresh MCP `ServerSession`, handles the request, and discards. No `Mcp-Session-Id` header tracking. This matches our model — each sandbox session is independent, and the CLI handles retries.

### JSON response mode, not SSE

`json_response=True` means the endpoint returns plain JSON for tool results instead of SSE streams. Simpler, more debuggable, no streaming complexity for what are essentially synchronous tool calls.

### Why not call existing REST endpoints from tools?

Tools call internal Python services directly (brain service, session store, daily module functions) rather than making HTTP loopback requests. Avoids auth middleware re-entry, reduces latency, and doesn't require the server to be its own client.

### CORS not needed

Container-to-host is a direct HTTP call, not a browser request. No CORS middleware needed.

## Key Files

| File | Action |
|------|--------|
| `computer/pyproject.toml` | Add `mcp` dependency |
| `computer/parachute/lib/sandbox_tokens.py` | **New** — token store |
| `computer/parachute/api/mcp_bridge.py` | **New** — HTTP MCP endpoint + auth |
| `computer/parachute/api/mcp_tools.py` | **New** — tool handlers |
| `computer/parachute/server.py` | Mount MCP endpoint, integrate lifespan |
| `computer/parachute/core/daily_agent.py` | Replace stdio MCP with HTTP MCP config |
| `computer/parachute/lib/mcp_loader.py` | Update outdated docstring |
| `computer/tests/test_mcp_bridge.py` | **New** — integration test |

## Dependencies & Risks

| Risk | Mitigation |
|------|------------|
| CLI might not support HTTP MCP in `--mcp-config` JSON format | SDK types confirm it; test early in Step 5 |
| `StreamableHTTPSessionManager` lifespan conflicts with FastAPI | SDK has documented patterns for embedding; use `session_manager.run()` in lifespan |
| Container can't reach `host.docker.internal:3333` | Already works — `daily_tools_mcp.py` uses this exact URL today |
| Token leaks if container is compromised | Tokens are session-scoped, short-lived, revoked on completion; sandboxed trust limits blast radius |

## Out of Scope

- Fixing stdio MCP in Docker (separate investigation, #234 original scope)
- Fixing builtin `parachute` MCP host path leaking (#235)
- Caller architecture redesign (#236)
- Dynamic per-module tool registration (future enhancement)
- Multi-server MCP routing (future — right now one endpoint serves all sandbox tools)
