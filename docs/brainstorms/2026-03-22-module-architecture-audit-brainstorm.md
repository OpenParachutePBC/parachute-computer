---
title: "Module architecture audit — modules as views"
date: 2026-03-22
issue: 306
---

# Module Architecture Audit

## What's happening now

Two modules exist: **chat** and **daily**. In practice:

- **Chat module** is hollow — it registers one table (Exchange) and has zero routes. All chat functionality lives in core (orchestrator, session manager, api/chat.py, api/sessions.py).
- **Daily module** is overstuffed — it owns Note, Card, Agent, AgentRun schemas plus ~50 API routes for journals, agents, cards, and scheduling.
- **Core already duplicates module schemas** — `brain_chat_store.py` registers the Note table because the orchestrator needs context notes even when the daily module isn't loaded.

## The problem

Schemas registered by modules are actually system-wide concerns:

| Schema | Registered by | Used by |
|--------|--------------|---------|
| Note | Daily + core (duplicated) | Orchestrator (context notes), MCP tools (write_note), Daily (journals) |
| Card | Daily | Bridge agent, Daily agents |
| Agent/AgentRun | Daily | Scheduler (core), Daily agent runner (core) |
| Exchange | Chat | Bridge agent (core) |

The module boundary doesn't match the usage boundary. These are all core data types that happen to have been born inside a module.

## Modules as views

The cleaner model: **modules are views, not owners**.

- **Core owns all schemas** — Note, Card, Agent, AgentRun, Exchange all register in `brain_chat_store.py` (or a dedicated `schema.py`)
- **Core owns shared services** — scheduling, agent dispatch, transcription (already true)
- **Modules provide UI-facing routes** — the daily module becomes a set of API endpoints that expose journal CRUD, agent management, card display. It doesn't own the data, it presents it.
- **Chat module dissolves** — its one table moves to core, and it already has no routes. Nothing left.

```
Before:
  Module owns: schema + routes + business logic
  Core owns: orchestrator + SDK + sessions

After:
  Core owns: schema + services + business logic
  Module provides: routes (API surface for a specific experience)
```

## What this means concretely

### Move to core
- Note, Card, Agent, AgentRun, Exchange table registration → `brain_chat_store.py`
- Agent seeding / redo log replay → server startup or a core initializer
- Column migrations → core schema evolution

### Keep in daily module
- `/api/daily/*` routes — journal CRUD, agent management UI, card display
- Daily-specific presentation logic (formatting entries, asset handling)

### Remove
- Chat module entirely (Exchange registration moves to core, no routes to keep)
- Duplicate Note registration in daily `on_load()`

## What about third-party modules?

Vault modules (user-installed) could still register their own tables via `on_load()`. The change is that **built-in schemas don't live in modules** — they're core infrastructure. Third-party modules can extend the graph with new node types, but they don't own the shared ones.

## Open questions

- Should `brain_chat_store.py` hold ALL schemas, or split into a `schema.py` that's called at startup?
- Should daily's agent seeding (built-in reflection/post-process agents) stay in the module or become a core fixture?
- Does the module loader need changes, or do we just move code and delete the chat module?
- Is "module = routes only" the right long-term abstraction, or should modules be able to provide more (e.g., scheduled jobs, hooks)?

## Scope

This is a refactor — no new features, no behavior change. The system works the same, but the ownership is clearer and schemas are available at startup regardless of which modules are loaded.
