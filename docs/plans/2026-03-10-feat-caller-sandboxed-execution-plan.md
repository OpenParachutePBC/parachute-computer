---
title: "Caller Sandboxed Execution"
type: feat
date: 2026-03-10
issue: 219
---

# Caller Sandboxed Execution

Route daily agent (Caller) execution through the same Docker sandbox infrastructure that Chat uses. Callers default to sandboxed — same isolation, MCP filtering, credential gating, and session management that Chat sessions get.

## Problem Statement

`run_daily_agent()` in `daily_agent.py` calls the Claude SDK directly in the main server process with `bypassPermissions`. No Docker container, no trust-level filtering, no capability gating. This is fine for a single-user dev setup but blocks the product path: Parachute Daily can't ship curated (or community) Callers that run with unrestricted host access.

The sandbox infrastructure is mature and battle-tested from Chat. The gap is that daily agents bypass it entirely.

## Proposed Solution

Refactor `run_daily_agent()` to build an `AgentSandboxConfig` and route through `DockerSandbox.run_session()` — the same path Chat's `_run_sandboxed()` uses. Each Caller gets a persistent container (like Chat projects). Daily-specific tools (read_journal, write_output, etc.) become a lightweight MCP that runs inside the container and calls back to the host API over the sandbox network.

## Design Decisions

**Daily tools → HTTP-backed MCP inside the container.** The current `create_daily_agent_tools()` creates in-process tools via `claude_agent_sdk`'s `@tool` decorator. These can't run inside a Docker container because they need direct graph access. Instead: a small Python MCP server script runs inside the container and makes HTTP calls to the host server (`http://host.docker.internal:3333/api/daily/...`). The host API already has journal read endpoints; we add a card-write endpoint.

**Each Caller gets a persistent container via project slug.** Container named `parachute-env-caller-{name}` (e.g., `parachute-env-caller-reflection`). State persists across runs — long-running Callers accumulate context in their SDK session history. Uses the same `DockerSandbox.ensure_container()` → `run_session()` path as Chat.

**`trust_level` field on Caller, default `"sandboxed"`.** Added as a column on the Caller graph schema. The scheduler and trigger endpoints read this field to decide sandboxed vs. direct execution. Power users can set to `"direct"` for specific Callers.

**Fallback to direct if Docker unavailable.** Same pattern as Chat — check Docker availability, log a warning, fall back to the current direct execution path. This keeps local dev working without Docker and avoids breaking existing Caller runs during the transition.

**Session management stays file-based for now.** The `DailyAgentState` file-based tracking works and migrating to `SessionManager` is orthogonal. Containers already handle SDK session resume via the home directory bind-mount. Migrate to SessionManager in a follow-up if needed.

## Implementation Phases

### Phase 1: Schema + API

**Add `trust_level` column to Caller schema** (`modules/daily/module.py`)

In `_ensure_new_columns()`, add migration for the `Caller` table:

```python
caller_cols = await graph.get_table_columns("Caller")
if "trust_level" not in caller_cols:
    await graph.execute_cypher(
        "ALTER TABLE Caller ADD trust_level STRING DEFAULT 'sandboxed'"
    )
```

Also update the `ensure_node_table("Caller", ...)` definition to include `"trust_level": "STRING"`.

Update the CRUD API endpoints to read/write `trust_level`:
- `POST /callers` and `PUT /callers/{name}` — accept and persist `trust_level`
- `GET /callers` and `GET /callers/{name}` — already return all columns, no change needed

**Add card-write API endpoint** (`modules/daily/module.py`)

The `write_output` tool inside the container needs to write Cards to the graph via the host API. Add:

```
POST /api/daily/cards/write
Body: { agent_name, date, content, display_name? }
```

This does the same MERGE + HAS_CARD linking that `write_output` in `daily_agent_tools.py` does today, but exposed as a REST endpoint. Returns the created/updated Card.

**Files changed:**
- `modules/daily/module.py` — schema migration, CRUD updates, new endpoint

### Phase 2: Container-Side Daily Tools MCP

**New file:** `computer/parachute/docker/daily_tools_mcp.py`

A standalone MCP server script that runs inside the container (started by the SDK as a configured MCP). Exposes the same tools daily agents use today, but backed by HTTP calls to the host:

| Tool | Container Implementation |
|------|------------------------|
| `read_journal` | `GET /api/daily/entries?date={date}` → format as markdown |
| `read_chat_log` | Read from mounted vault at `/home/sandbox/Parachute/Daily/chat-log/{date}.md` |
| `read_recent_journals` | `GET /api/daily/entries?date={date}` for each recent date |
| `read_recent_sessions` | Read from mounted vault chat-log directory |
| `write_output` | `POST /api/daily/cards/write` with `{agent_name, date, content}` |

The script uses `httpx` (already in the sandbox image) for HTTP calls. Agent name and host URL are passed via environment variables (`PARACHUTE_CALLER_NAME`, `PARACHUTE_HOST_URL`).

This script is mounted into the container via the tools volume or a direct bind-mount. It's configured as an MCP in the capabilities JSON passed to the container's entrypoint.

**Files changed:**
- `computer/parachute/docker/daily_tools_mcp.py` — new file

### Phase 3: Refactor `run_daily_agent()` for Sandbox Routing

**Core change:** `daily_agent.py` — refactor `run_daily_agent()` to route through the sandbox when `trust_level == "sandboxed"` and Docker is available.

New flow:
1. Load `DailyAgentConfig` from graph (existing)
2. Read `trust_level` from the Caller config (new — add to `DailyAgentConfig.from_row()`)
3. If `trust_level == "sandboxed"` and Docker is available:
   a. Get or create `DockerSandbox` instance (from orchestrator's singleton or service registry)
   b. Build `AgentSandboxConfig`:
      - `session_id` = `f"caller-{agent_name}-{date}"` (deterministic for resume)
      - `agent_type` = `"caller"`
      - `network_enabled` = `True` (needs to reach host API)
      - `mcp_servers` = `{"daily_tools": {config for daily_tools_mcp.py}}` + trust-filtered vault MCPs
      - `system_prompt` = formatted system prompt (existing logic)
      - `session_source` = `None` (no credential injection for Callers)
   c. Create project slug `caller-{agent_name}` for persistent container
   d. Ensure project record exists in BrainSessionStore (like Chat's auto-project)
   e. Call `sandbox.run_session()` with message, config, project_slug
   f. Process streaming events — watch for `write_output` tool calls to detect card completion
   g. Update `DailyAgentState` on completion (existing)
4. If `trust_level == "direct"` or Docker unavailable: run existing direct path (current code, extracted to `_run_direct()`)

**Write initial "running" Card before sandbox execution** — existing logic in `run_daily_agent()` already does this via graph, keep it.

**Mark Card as done/failed after sandbox completes** — process the stream events to detect completion. The `write_output` tool in the container MCP writes the card via API, but we still need to handle the "failed" case if the container errors out.

**Vault MCP filtering** — load vault MCPs via `load_vault_mcps()` (existing), then filter with `filter_by_trust_level(mcps, "sandboxed")` so Callers only get sandboxed-compatible MCPs.

**Files changed:**
- `computer/parachute/core/daily_agent.py` — main refactor
- `computer/parachute/core/daily_agent.py` — add `trust_level` to `DailyAgentConfig`

### Phase 4: Wire Scheduler + Trigger Endpoints

The scheduler (`scheduler.py`) calls `run_daily_agent()` via `_run_daily_agent_job()`. Since we're changing `run_daily_agent()`'s internal routing (not its signature), the scheduler needs minimal changes:

- Pass `DockerSandbox` instance to `run_daily_agent()` (new optional param) — or have `run_daily_agent()` obtain it from the service registry
- The service registry approach is cleaner: `run_daily_agent()` calls `get_registry().get("DockerSandbox")` at invocation time, same as it already does for `BrainDB`

The trigger endpoint in `module.py` (`POST /cards/{agent_name}/run`) already calls `run_daily_agent()` via `asyncio.create_task()`. This continues to work since the function signature doesn't change.

**Files changed:**
- `computer/parachute/core/daily_agent.py` — get sandbox from registry
- `computer/parachute/core/scheduler.py` — no changes needed (transparent)
- `modules/daily/module.py` — no changes needed (transparent)

## Acceptance Criteria

- [x] Caller graph schema has `trust_level` column (default `"sandboxed"`)
- [x] CRUD API reads/writes `trust_level` field
- [x] New `POST /api/daily/cards/write` endpoint writes Cards to graph
- [x] `daily_tools_mcp.py` runs inside containers and can read journals + write cards via host API
- [x] `run_daily_agent()` routes through Docker sandbox when `trust_level == "sandboxed"` and Docker is available
- [x] Each Caller gets a persistent container (`parachute-env-caller-{name}`)
- [x] Vault MCPs are trust-filtered before passing to container
- [x] Falls back to direct execution when Docker unavailable (with warning log)
- [x] Existing scheduled + manual trigger flows continue working unchanged
- [x] Card status tracking (running → done/failed) works for sandboxed execution

## Technical Considerations

**Container access to host API.** Sandbox containers on the `parachute-sandbox` Docker network can reach the host via `host.docker.internal:3333`. This is already configured (`--add-host host.docker.internal:host-gateway` in `sandbox.py`). The daily tools MCP uses this for journal reads and card writes.

**No credential injection for Callers.** `session_source` is set to `None`, which means `_run_in_container()` won't inject host credentials into the container. Callers don't need them — they interact with the host via the daily tools MCP and whatever vault MCPs pass the trust filter.

**Graph access for initial Card write.** The "running" Card is written to the graph by the host process *before* the container starts (existing behavior). The final card content is written by the container's `write_output` tool via the host API. Card failure marking happens on the host after the container stream ends.

**Deterministic session IDs.** Using `caller-{name}-{date}` as session_id means re-running a Caller for the same date will attempt to resume the previous session. This matches the existing behavior where `DailyAgentState.sdk_session_id` enables resume.

## Dependencies & Risks

- **Docker must be running for sandboxed Callers.** Same risk as Chat — mitigated by fallback to direct execution. The Docker runtime management feature (#209) addresses this at the system level.
- **Host API must be reachable from container.** Depends on `host.docker.internal` working (OrbStack/Docker Desktop on macOS both support this). Linux may need `--add-host` flag — already present in `sandbox.py`.
- **daily_tools_mcp.py must be included in the sandbox image or mounted.** Simplest path: mount from the repo directory as a read-only bind mount, alongside the existing capabilities mounts.

## Out of Scope

- Migrating `DailyAgentState` to `SessionManager` (follow-up)
- Caller management UI (issue #221)
- Card experience polish (issue #220)
- Voice post-processing as a Caller
- Community Caller sharing/marketplace
