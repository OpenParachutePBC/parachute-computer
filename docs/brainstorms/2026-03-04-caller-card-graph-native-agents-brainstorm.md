---
title: "Caller & Card — Graph-Native Agent Definitions"
date: 2026-03-04
status: brainstorm
priority: P1
tags: [daily, computer, graph, agents]
---

# Caller & Card — Graph-Native Agent Definitions

## Context

The `AgentCard` PR (#179) moved agent *outputs* from vault markdown files into the graph as `AgentCard` nodes. That was the right first step. But agent *definitions* still live as vault files (`Daily/.agents/*.md`), which is now inconsistent — the vault is being deprecated as the source of truth in favor of `~/.parachute` and the graph.

This brainstorm addresses the other half: moving agent *definitions* into the graph too.

## Simpler Primitives

As part of this work, we're also simplifying the naming:

- **`Caller`** — agent definition (was: vault `.agents/*.md` files + `DailyAgentConfig`)
- **`Card`** — agent output (was: `AgentCard`)

These are shorter, more system-agnostic names that fit the graph-native model better.

## What We're Building

A **`Caller`** node in the graph holds everything a daily agent needs to be discovered, scheduled, and run:

- Identity: `name` (PK), `display_name`, `description`
- Instructions: `system_prompt` (the full markdown body, previously the .md file body)
- Execution: `tools` (JSON list), `model`
- Schedule: `schedule_enabled`, `schedule_time`
- Lifecycle: `enabled`, `created_at`, `updated_at`

The relationship `HAS_CALLER` links `Day → Caller` is NOT needed — callers are global, not per-day. Cards remain linked to Day via `HAS_CARD` (renamed from `HAS_AGENT_CARD`).

## Why This Approach

The vault file approach was a reasonable starting point but has accumulated several problems:

1. **Wrong source of truth** — vault files are being deprecated; graph is canonical
2. **No app management** — users can't create/edit/delete agents from Flutter
3. **Discovery is fragile** — file scanning can fail silently, order is undefined
4. **Inconsistency** — outputs (Cards) are in the graph but definitions (Callers) are in files

Moving Callers to the graph makes the full agent lifecycle graph-native: define → run → output all live in the same store.

## Migration Strategy

One-time migration on module startup:

1. Scan `vault_path/Daily/.agents/*.md` for existing agent definitions
2. For each file: parse YAML frontmatter (config) + markdown body (system prompt)
3. `MERGE` into graph as `Caller` node — idempotent, safe to re-run
4. Vault files become stale artifacts — ignored by the system, not deleted (user may reference them)

Migration runs before the scheduler initializes, so by the time jobs are created, all callers are in the graph.

## Key Decisions

**Full definition in graph (including system prompt)**
The system prompt is a string field on the Caller node. It's the full markdown instructions previously in the .md file body. This is slightly less ergonomic for authoring (no syntax highlighting), but the app-management use case requires it, and it removes the file dependency entirely.

**`discover_daily_agents()` queries graph instead of filesystem**
The core discovery function becomes a graph query: `MATCH (c:Caller) WHERE c.enabled = true RETURN c`. The scheduler bootstraps from this.

**Scheduler reload reads from graph**
`POST /api/scheduler/reload` re-queries the graph rather than re-scanning files. Callers can be added/updated/deleted via API and the scheduler picks up changes on reload.

**CRUD API on Callers**
- `GET /callers` — list all callers
- `GET /callers/{name}` — get one
- `POST /callers` — create (from Flutter, eventually)
- `PUT /callers/{name}` — update
- `DELETE /callers/{name}` — delete

Flutter CRUD UI is out of scope for this brainstorm — the API exists for it, but the UI work is future.

**Rename AgentCard → Card in this PR**
Since we're touching the graph schema and module.py anyway, rename `AgentCard` → `Card` and `HAS_AGENT_CARD` → `HAS_CARD` to establish the simpler primitive names now. Avoids a separate rename PR later.

## What Changes

**Backend:**
- `module.py`: Add `Caller` node table + `HAS_CALLER`? No — callers are not per-day. Add migration logic. Rename `AgentCard` → `Card`.
- `daily_agent.py`: `discover_daily_agents()` → query graph. `get_daily_agent_config()` → query graph. Migration function.
- `scheduler.py`: Load callers from graph instead of file scan.
- New API routes: CRUD on `/callers`

**Flutter:**
- Rename `AgentCard` model → `Card`
- Update `agentCardsProvider` → `cardsProvider`
- Update API calls from `/agent-cards` → `/cards`
- `fetchAgents()` → `fetchCallers()`

## Open Questions

- Should `Caller` nodes be linked to a `Module` node (daily, chat, etc.) for future multi-module agents? Probably not yet — YAGNI.
- What's the UX for authoring system prompts in the app? Multi-line text field for now, dedicated editor later.
- Do we want to version system prompts (track changes over time)? Not in this PR.
- Should the migration run once and mark vault files as "migrated" (e.g., rename to `.migrated`)? Or just run idempotently forever? Idempotent MERGE is simpler — no state to manage.

**Issue:** #181
