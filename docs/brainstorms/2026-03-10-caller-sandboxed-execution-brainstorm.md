# Caller Sandboxed Execution

**Status:** Brainstorm
**Priority:** P1
**Labels:** daily, computer
**Issue:** #219

---

## What We're Building

Route Caller (daily agent) execution through the same Docker sandbox infrastructure that Chat sessions use. Today `run_daily_agent()` calls the Claude SDK directly in the main server process with `bypassPermissions` — no isolation, no capability filtering, full host access. This wires Callers through the orchestrator's sandboxed execution path so they get proper Docker isolation, trust-level-aware MCP filtering, and session resume.

**Default: sandboxed.** Callers run in Docker containers by default. Direct (unsandboxed) execution is a rare override for power users, not the norm. This is a foundational decision — almost everything should be sandboxed.

## Why This Matters

Parachute Daily is the product path. Callers are its core primitive — they generate the Cards that make Daily worth opening. For Daily to work as a hosted product with curated (and eventually community) Callers, agents can't run with unrestricted host access. The sandbox infrastructure is mature and battle-tested from Chat. Reusing it avoids building new isolation primitives and gives Callers the same security properties that Chat sessions already have.

This also unblocks the hosted offering — you can't run untrusted agent code on shared infrastructure without containerization.

## Current State

**Daily agent execution** (`daily_agent.py`):
- `run_daily_agent()` imports `ClaudeAgentOptions` and calls `query()` directly
- `permission_mode` hardcoded to `bypassPermissions`
- Daily-specific tools created via `create_daily_agent_tools()` (read_journal, read_chat_log, write_output, etc.)
- State tracked in `DailyAgentState` (file-based: `Daily/.{agent_name}/state.json`)
- Scheduler calls `run_daily_agent()` directly via `_run_daily_agent_job()`

**Chat sandboxed execution** (`orchestrator.py` + `sandbox.py`):
- `_run_sandboxed()` creates `AgentSandboxConfig`, calls `sandbox.run_session()`
- SDK runs inside Docker container via entrypoint
- MCPs filtered by trust level via `capability_filter.py`
- Credentials injected conditionally (non-bot sessions only)
- Session metadata stored in SQLite, transcripts in JSONL
- Container lifecycle: create/reuse/timeout managed by `DockerSandbox`

**The gap**: Daily agents bypass all of this. They run on the host with full access.

## Key Decisions

**Reuse orchestrator path, don't build new sandbox plumbing.**
The goal is to make `run_daily_agent()` call into the same capability discovery + sandbox routing that `_run_sandboxed()` uses. This means Callers get MCP filtering, credential gating, container isolation, and transcript persistence for free.

**Each Caller gets its own container (like Chat projects).**
A Caller's container persists across runs using the same project-slug mechanism Chat uses. The "reflection" Caller gets a `reflection` container that accumulates state. This enables long-running Callers that build context over time.

**`trust_level` field on Caller definition.**
Add `trust_level` to the Caller graph schema. Defaults to `sandboxed`. Power users can set to `direct` for specific Callers they trust. The scheduler and trigger endpoints respect this field when routing execution.

**Daily-specific tools become MCPs.**
The current `create_daily_agent_tools()` functions (read_journal, read_chat_log, write_output) need to be accessible inside the container. Options: (a) expose them as an MCP server the container can reach, or (b) mount them as tools in the sandbox entrypoint. MCP server is more consistent with how Chat works.

**Fallback to direct if Docker unavailable.**
Same pattern as Chat — check Docker availability, warn if unavailable, optionally fall back to direct execution with a log warning. This keeps local dev working without Docker.

**Session management migrates to SessionManager.**
Replace `DailyAgentState` (file-based) with the same `SessionManager` that Chat uses. Daily agent sessions show up in the sessions database, can be browsed, and support resume via SDK session IDs.

## What Changes

**Backend (`computer/`):**
- `daily_agent.py`: Refactor `run_daily_agent()` to build `AgentSandboxConfig` and call through sandbox path
- `daily_agent.py`: Add `trust_level` parameter, default `sandboxed`
- `module.py`: Add `trust_level` column to Caller graph schema (default: `"sandboxed"`)
- `module.py`: Expose daily tools as MCP server accessible from container
- `scheduler.py`: No structural changes — underlying execution path changes transparently
- `session_manager.py`: Daily agent sessions stored alongside chat sessions

**No Flutter changes needed** — this is entirely backend plumbing. The Card output API stays the same.

## Open Questions

- Should daily agent containers share a network with Chat containers, or have their own? Probably same network — simpler.
- Do we need resource limits (CPU/memory) different from Chat containers for daily agents? Start with same defaults.
- How do we handle the transition for existing `DailyAgentState` files? Probably just let them age out — new sessions go to SessionManager, old state files ignored.
