---
title: Sandbox MCP HTTP Bridge
issue: 234
date: 2026-03-12
status: brainstorm
labels: [computer, bug, P2]
---

# Sandbox MCP HTTP Bridge

## The Problem

MCP stdio servers don't work inside Docker sandbox containers. When the Claude CLI runs inside a container (via `entrypoint.py` → Agent SDK → CLI), stdio MCP servers configured via `--mcp-config` JSON are never connected. The agent can't see the tools — calls return "No such tool available."

**What works:** The MCP server script runs correctly inside the container (manual LSP protocol tests succeed). The SDK builds correct `--mcp-config` JSON. The CLI receives the config.

**What doesn't:** The CLI never registers the tools. No error is emitted. The failure is silent.

This blocks:
- **Callers** (daily agents) from accessing journal data, chat logs, and writing output
- **Sandboxed chat sessions** from accessing any MCP tools
- Any future feature that needs sandboxed agents with host-side tools

## Context

The current MCP flow for sandboxed sessions:

```
Host: orchestrator.py → sandbox.py → docker exec
  stdin payload: { capabilities: { mcp_servers: { "daily": { command: "python", args: [...] } } } }

Container: entrypoint.py → ClaudeAgentOptions(mcp_servers=...) → SDK → CLI
  CLI receives: --mcp-config '{"mcpServers":{"daily":{"command":"python","args":[...]}}}'
  CLI should: spawn subprocess, connect via LSP framing, register tools
  CLI actually: ??? (silent failure, no tools registered)
```

The built-in `parachute` MCP server uses a host-local Python path that doesn't exist in containers — this is a separate issue (#235), but compounds the problem.

## What We Learned

### The SDK supports HTTP MCP natively

The Claude Agent SDK (v0.1.30+) has full support for HTTP MCP servers:

```python
# types.py
class McpHttpServerConfig(TypedDict):
    type: Literal["http"]
    url: str
    headers: NotRequired[dict[str, str]]
```

The SDK serializes HTTP configs to `--mcp-config` JSON exactly like stdio configs — no filtering, no special handling. The MCP library includes a complete `StreamableHTTPTransport` with session management, reconnection, and SSE fallback.

### The stdio filter is only used by daily_agent.py

`filter_stdio_servers()` in `mcp_loader.py` has an outdated docstring claiming "The Claude SDK only supports stdio." In reality:
- The main orchestrator (`orchestrator.py`) passes ALL resolved MCPs to the SDK without filtering
- Only `daily_agent.py` calls `filter_stdio_servers()` before building sandbox configs
- HTTP configs would pass through the main orchestrator path just fine

### Streamable HTTP is the current MCP transport spec

SSE transport is deprecated. Streamable HTTP uses a single POST endpoint for requests (returning JSON or SSE streams) and an optional GET endpoint for server-initiated messages. The Claude Code CLI supports `--transport http` natively.

## Approaches

### A: HTTP MCP Server on the Host (Recommended)

Build an MCP-compliant HTTP endpoint on the Parachute server. Sandbox containers connect to it over the Docker network — no subprocess spawning, no stdio piping.

```
Container: CLI → HTTP request → http://host.docker.internal:3333/mcp/v1
Host: FastAPI endpoint → authenticates → routes to MCP handler → returns JSON/SSE
```

**How it works:**
1. New FastAPI route at `/mcp/v1` implements the Streamable HTTP MCP transport
2. Sandbox configs include an HTTP MCP server pointing to the host:
   ```python
   mcp_servers = {
       "parachute": {
           "type": "http",
           "url": "http://host.docker.internal:3333/mcp/v1",
           "headers": {"Authorization": "Bearer <session-scoped-token>"}
       }
   }
   ```
3. The server authenticates requests using a session-scoped token (passed at container start)
4. Tool dispatch reads session context (trust level, project, session ID) from the token
5. Permission enforcement happens server-side — the container never gets unauthorized access

**Tools exposed (initial set):**
- `read_journal(date)` — read a specific journal entry
- `read_recent_journals(days)` — read recent journal entries
- `read_chat_log(session_id)` — read a chat transcript
- `read_recent_sessions(limit)` — list recent chat sessions
- `search_memory(query)` — search across all memory
- `read_brain_entity(name)` — read a brain graph entity
- `write_output(content, title)` — write agent output (card content, etc.)

**Read by default, write explicitly:** All read tools available by default. Write tools are opt-in per session configuration. This matches the principle: sandboxed agents can see everything, but writing happens through purpose-built operations.

**Advantages:**
- Eliminates the stdio subprocess spawning problem entirely
- Server-side permission enforcement (container can't bypass)
- Session-scoped auth tokens enable fine-grained per-session permissions
- Works for ALL sandboxed sessions (callers, chat, future agents)
- Infrastructure reusable for any future MCP consumers (other apps, external agents)
- No new dependencies — FastAPI already handles HTTP, MCP library has transport code

**Disadvantages:**
- New endpoint to build and maintain
- Auth token management (generation, validation, expiry)
- Network dependency (container must reach host — but `host.docker.internal` already works for us)

**Complexity:** Medium. ~300-400 lines of new server code. Most of it is routing MCP protocol messages to existing module functions.

### B: Debug and Fix Stdio in Docker

Figure out why the CLI silently fails to connect stdio MCP servers inside containers and fix the root cause.

**Investigation steps:**
1. Add `--mcp-debug` flag to CLI invocation in entrypoint
2. Capture CLI stderr during MCP initialization
3. Test with minimal MCP server (echo server) to isolate
4. Check if `env` field in MCP config replaces vs merges parent env
5. Check if CLI has a timeout for MCP server initialization

**Advantages:**
- Fixes the actual bug rather than working around it
- No new infrastructure — existing configs just work
- Simpler mental model (same MCP flow everywhere)

**Disadvantages:**
- Root cause is unknown and may be in the CLI (which we don't control)
- Even if fixed, stdio subprocess spawning in containers is fragile
- Each container still needs MCP server scripts copied in
- No server-side permission enforcement
- Doesn't solve the `parachute` builtin MCP problem (#235)

**Complexity:** Unknown. Could be a one-line env fix or could be a CLI bug we can't fix.

### C: In-Process SDK MCP Server

Use the SDK's `@tool` decorator and `create_sdk_mcp_server()` to run tools in-process — no subprocess, no HTTP, no transport layer.

```python
from claude_agent_sdk import tool, create_sdk_mcp_server

@tool("read_journal")
async def read_journal(date: str) -> str:
    """Read a journal entry by date."""
    resp = await httpx.get(f"http://host.docker.internal:3333/api/daily/journal/{date}")
    return resp.text

mcp_servers = {"daily": create_sdk_mcp_server([read_journal])}
options = ClaudeAgentOptions(mcp_servers=mcp_servers)
```

**Advantages:**
- Zero transport complexity — tools run in the same process as the SDK
- No subprocess spawning, no HTTP, no auth tokens
- Proven to work (SDK type `"sdk"` with `"instance"` key)

**Disadvantages:**
- Tools execute inside the container with container permissions
- No server-side permission enforcement — container has full tool access
- Requires modifying entrypoint.py to define tools (couples tool definitions to Docker image)
- Tool code in the container makes HTTP calls back to host anyway
- Can't easily share tool definitions across different container images
- Breaks the clean separation between "agent runs in container" and "tools live on host"

**Complexity:** Low initially, but creates coupling and maintenance burden.

## Recommendation

**Approach A (HTTP MCP Server)** is the right call. It:

1. **Solves the right problem** — sandboxed agents need host tools, and the cleanest boundary is HTTP
2. **Enables per-session permissions** — the server knows who's asking and can enforce rules
3. **Works for everything** — callers, chat, future agents all use the same bridge
4. **Aligns with MCP direction** — Streamable HTTP is the current transport spec
5. **Eliminates a class of bugs** — no more debugging subprocess spawning inside containers

Approach B is worth doing eventually (it's a real bug), but it doesn't solve the architectural problem. Approach C is a quick hack that creates coupling we'd want to remove later.

### Implementation sketch

**Phase 1: Minimal HTTP MCP endpoint**
- FastAPI route at `/mcp/v1` handling MCP `initialize`, `tools/list`, `tools/call`
- Simple bearer token auth (token generated per sandbox session, passed via MCP headers)
- 3-4 read tools: `read_journal`, `read_recent_journals`, `search_memory`, `read_brain_entity`
- 1 write tool: `write_output` (for callers writing card content)

**Phase 2: Sandbox integration**
- Modify sandbox config builder to include HTTP MCP server pointing to host
- Remove `filter_stdio_servers()` from daily_agent.py (no longer needed)
- Remove copied MCP scripts from container (no longer needed)
- Test with existing callers

**Phase 3: Permission system**
- Token carries session context (trust level, allowed tools, project scope)
- Server-side middleware checks permissions before dispatching tool calls
- Different sandbox sessions can have different tool sets

### Open questions

1. **Token format** — JWT (self-contained, no lookup) vs opaque (server-side lookup, revocable)? Start with opaque for simplicity — just a random string mapped to session context in memory.

2. **Stateless vs stateful MCP** — Streamable HTTP supports both. Start stateless (no session management on the MCP side) since each sandbox session is independent.

3. **Tool registration** — Static list of tools, or dynamically registered per module? Start static, evolve to module-contributed tools later.

4. **Existing `daily_tools_mcp.py`** — Keep it for reference during implementation, delete once HTTP endpoint covers its tools.
