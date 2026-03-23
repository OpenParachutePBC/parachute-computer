---
title: "Modules as views — centralize schemas in core"
type: refactor
date: 2026-03-22
issue: 306
---

# Modules as views — centralize schemas in core

Move all schema registration, migrations, and seeding from modules into core. Modules become route providers only — views into shared data, not data owners.

## Problem

The daily module owns schemas (Note, Card, Agent, AgentRun) that are system-wide concerns. Core already duplicates Note registration because the orchestrator needs context notes even when daily isn't loaded. The chat module is hollow — it registers one table (Exchange) and has no routes.

## Proposed Solution

### Phase 1: Move schemas to `brain_chat_store.py`

Add to `ensure_schema()` (which already has Chat, Container, PairingRequest, Note):

- **Card** — from daily module
- **Agent** — from daily module
- **AgentRun** — from daily module
- **Exchange** + **HAS_EXCHANGE** rel — from chat module

All column definitions copy verbatim from the module code. `ensure_node_table` is idempotent, so no migration risk.

### Phase 2: Move migrations to `brain_chat_store.py`

Move `_ensure_new_columns()` from daily module into `BrainChatStore.ensure_schema()`. This includes column migrations for Note, Agent, and AgentRun tables. Follow the same pattern already used for Chat/Container migrations (lines 99-115 of brain_chat_store.py).

### Phase 3: Move agent seeding to core

Move `_seed_builtin_agents()` and `AGENT_TEMPLATES` from the daily module to a core location. Options:

- **A)** Into `BrainChatStore` as a post-schema method called from `ensure_schema()`
- **B)** Into a new `parachute/core/agent_seeder.py` called from server startup

Option A is simpler. The templates are small and seeding is idempotent.

### Phase 4: Simplify daily module's `on_load()`

Daily `on_load()` becomes:
- Redo log replay (daily-specific — journal crash recovery)
- Audio path migration (daily-specific — one-time migration)
- Nothing else

### Phase 5: Delete chat module

The chat module's only job is registering Exchange + HAS_EXCHANGE, which moved to core in Phase 1. It has no routes (`get_router()` returns None). Delete `modules/chat/` entirely.

Update `module_loader.py` if it has any hardcoded references to chat.

### Phase 6: Clean up duplicate Note registration

Remove the duplicate Note `ensure_node_table` call from daily `on_load()`. Core now owns it. The daily module should trust that the schema exists by the time `on_load()` runs (server calls `ensure_schema()` before loading modules).

## Acceptance Criteria

- [x] Card, Agent, AgentRun, Exchange tables registered in `brain_chat_store.py`
- [x] HAS_EXCHANGE relationship registered in `brain_chat_store.py`
- [x] Column migrations moved from daily module to core
- [x] Agent seeding moved from daily module to core
- [x] Chat module deleted
- [x] Duplicate Note registration removed from daily `on_load()`
- [x] Daily `on_load()` only does daily-specific initialization (redo log, audio migration)
- [x] All existing tests pass
- [x] Server starts and schemas are created correctly without daily module loaded

## Context

- `ensure_node_table` is idempotent — safe to call multiple times with the same schema
- `BrainChatStore.ensure_schema()` already registers Chat, Container, PairingRequest, Note (lines 53-156)
- Daily module's `_ensure_new_columns()` handles migrations for Note, Agent, AgentRun (lines 680-754)
- Daily module's `_seed_builtin_agents()` creates reflection/post-process agents (lines 756-870)
- `AGENT_TEMPLATES` defined at top of `modules/daily/module.py`
- Chat module at `modules/chat/module.py` — ~55 lines, only registers Exchange table
- Module loader at `parachute/core/module_loader.py`
- Server startup at `parachute/server.py` — calls `ensure_schema()` then loads modules
