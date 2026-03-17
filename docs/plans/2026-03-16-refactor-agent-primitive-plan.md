---
title: "Rename Callers to Agents + memory mode"
type: refactor
date: 2026-03-16
issue: 280
---

# Rename Callers to Agents + Memory Mode

Rename the "Caller" primitive to "Agent" throughout the codebase and add a configurable memory mode (persistent vs. fresh) per agent. This is a mechanical rename (~410 changes) plus one small feature addition.

## Problem Statement

"Caller" doesn't resonate as a product term. The UI already says "Daily Agents" but the code says "Caller" everywhere — graph nodes, API endpoints, class names, file names. Users should see "Agent" consistently, and developers should work with "Agent" in code.

Additionally, session persistence is currently hard-wired: scheduled agents always resume their session, triggered agents always start fresh. Making this a per-agent toggle ("memory mode") unlocks new patterns — e.g., a triggered agent that accumulates context across notes, or a scheduled agent that starts fresh every day.

## Proposed Solution

Four phases, each independently shippable:

1. **Backend rename** — Graph schema, Python files, classes, functions
2. **API rename** — Endpoints from `/callers/*` to `/agents/*` with backward-compat aliases
3. **Flutter rename** — Dart files, classes, providers, UI strings
4. **Memory mode** — New `memory_mode` field on Agent node, wired through execution

## Acceptance Criteria

- [ ] Graph node types are `Agent` and `AgentRun` (migrated from `Caller`/`CallerRun`)
- [ ] All API endpoints use `/agents/*` as primary path
- [ ] `/callers/*` endpoints kept as backward-compat aliases (can remove later)
- [ ] All Python class/function names use "Agent" not "Caller"
- [ ] All Dart class/file/provider names use "Agent" not "Caller"
- [ ] All user-facing strings say "agent" not "caller"
- [ ] New `memory_mode` field: `"persistent"` (default) or `"fresh"`
- [ ] Memory mode respected in both `run_daily_agent()` and `run_triggered_agent()`
- [ ] All existing tests pass (renamed) + new test for memory mode
- [ ] `flutter analyze` clean
- [ ] Templates updated: daily-reflection defaults to persistent, auto-tagger defaults to fresh

## Technical Considerations

### Graph Migration

LadybugDB doesn't support `ALTER TABLE RENAME`. Migration strategy:
1. Create new `Agent` and `AgentRun` node tables with identical schemas (+ `memory_mode` column)
2. Copy all data from `Caller` → `Agent` and `CallerRun` → `AgentRun`
3. Re-create relationships (HAS_RUN, etc.) pointing to new tables
4. Drop old `Caller` and `CallerRun` tables

This runs in `_ensure_schema()` on server startup, gated by a migration check (e.g., check if `Agent` table exists).

### Namespace: Daily Agents vs SDK Agents

No conflict. Daily agents live at `/api/daily/agents/*` (module router). SDK agents live at `/api/agents` (core router). The URL prefix disambiguates. The SDK agent scaffolding (`models/agent.py`, `api/agents.py`, `create_vault_agent()`) is **not touched** in this plan — it's a separate system managed by the Claude SDK.

### Backward Compatibility

- Old `/daily/callers/*` routes kept as aliases (one-line decorator duplication)
- Graph migration copies data — no data loss
- Flutter app deploys with the server — no version skew concern
- The existing `/daily/agents` alias (currently a backward-compat alias for `/daily/callers`) becomes the primary route

### Memory Mode Implementation

Add `memory_mode` column to Agent node (default: `"persistent"`). In execution:
- `_load_agent_state()`: if `memory_mode == "fresh"`, return empty `sdk_session_id`
- `_record_agent_run()`: if `memory_mode == "fresh"`, don't write `sdk_session_id` back
- Templates: daily-reflection → persistent, auto-tagger → fresh

## Implementation Phases

### Phase 1: Backend Rename (~200 changes)

**File renames:**
- `caller_dispatch.py` → `agent_dispatch.py`
- `triggered_caller_tools.py` → `triggered_agent_tools.py`
- `test_caller_dispatch.py` → `test_agent_dispatch.py`

**Graph schema migration** in `module.py`:
- Create `Agent` table (same columns as `Caller` + `memory_mode`)
- Create `AgentRun` table (same columns as `CallerRun`)
- Copy data + relationships
- Drop `Caller`/`CallerRun`

**Class/function renames** (use IDE rename or `gitnexus_rename` for safety):
- `CallerDispatcher` → `AgentDispatcher`
- `run_triggered_caller()` → `run_triggered_agent()`
- `create_triggered_caller_tools()` → `create_triggered_agent_tools()`
- `CALLER_TEMPLATES` → `AGENT_TEMPLATES`
- All `caller_name` params → `agent_name`
- All helper functions: `_load_caller_state` → `_load_agent_state`, etc.
- All Cypher queries: `(c:Caller)` → `(a:Agent)`, `(r:CallerRun)` → `(r:AgentRun)`

**Env var:** `PARACHUTE_CALLER_NAME` → `PARACHUTE_AGENT_NAME`

**Files touched:**
- `computer/parachute/core/agent_dispatch.py` (renamed)
- `computer/parachute/core/triggered_agent_tools.py` (renamed)
- `computer/parachute/core/daily_agent.py`
- `computer/modules/daily/module.py`
- `computer/parachute/core/daily_tools_mcp.py`
- `computer/parachute/api/mcp_tools.py`
- `computer/tests/unit/test_agent_dispatch.py` (renamed)

### Phase 2: API Rename (~10 endpoints)

In `module.py`, swap primary/alias:
- Primary: `/agents/*` (10 endpoints)
- Alias: `/callers/*` (backward-compat, same handlers)
- Update response keys: `"callers"` → `"agents"` where applicable
- Update `/entries/{entry_id}/caller-activity` → `/entries/{entry_id}/agent-activity`

### Phase 3: Flutter Rename (~200 changes)

**File renames:**
- `caller_management_screen.dart` → `agent_management_screen.dart`
- `caller_edit_screen.dart` → `agent_edit_screen.dart`
- `caller_detail_sheet.dart` → `agent_detail_sheet.dart`

**Class renames:**
- `CallerTemplate` → `AgentTemplate`
- `CallerActivity` → `AgentActivity`
- `CallerManagementScreen` → `AgentManagementScreen`
- `CallerEditScreen` → `AgentEditScreen`
- `CallerDetailSheet` → `AgentDetailSheet`
- All private state classes accordingly

**Provider renames:**
- `callersProvider` → `agentsProvider`
- `callerTemplatesProvider` → `agentTemplatesProvider`

**API method renames in `daily_api_service.dart`:**
- `fetchCallers()` → `fetchAgents()`
- `createCaller()` → `createAgent()`
- `updateCaller()` → `updateAgent()`
- `deleteCaller()` → `deleteAgent()`
- `resetCaller()`→ `resetAgent()`
- `triggerCallerOnEntry()` → `triggerAgentOnEntry()`
- `fetchCallerActivity()` → `fetchAgentActivity()`

**Update API paths** called by these methods to use `/agents/*`.

**User-facing strings:**
- "Edit caller" → "Edit agent"
- "Create a Caller" → "Create an Agent"
- "Get started with a Caller" → "Get started with an Agent"
- All remaining "Caller" → "Agent" in descriptions

**Import path updates** (~6 files importing renamed screens/widgets).

### Phase 4: Memory Mode

**Backend:**
- Add `memory_mode` column to Agent schema (default: `"persistent"`)
- `_load_agent_state()`: skip `sdk_session_id` when mode is `"fresh"`
- `_record_agent_run()`: skip writing `sdk_session_id` when mode is `"fresh"`
- Update `AGENT_TEMPLATES`: daily-reflection=persistent, auto-tagger=fresh
- Add to seed migration: set `memory_mode` on existing agents based on trigger type

**Flutter:**
- Add `memoryMode` field to `DailyAgentInfo`
- Add toggle to `AgentEditScreen` (only for advanced/power users? or always visible?)
- `AgentDetailSheet`: show memory mode in info section

**Test:**
- Unit test: `run_daily_agent()` with `memory_mode="fresh"` does not resume session
- Unit test: `run_triggered_agent()` with `memory_mode="persistent"` does resume session

## Dependencies & Risks

| Risk | Mitigation |
|------|------------|
| Graph migration fails on existing data | Migration is additive (create new, copy, drop old). Test with production-like data first. |
| Missed rename causes runtime error | Run full test suite + `flutter analyze` after each phase. Grep for leftover "caller"/"Caller" references. |
| `/callers/*` aliases add maintenance burden | Aliases are one-line decorators — minimal cost. Remove in a future release. |
| `AgentDefinition` (SDK) namespace confusion | Different URL prefix (`/api/agents` vs `/api/daily/agents`). No code overlap. |

## References

- Brainstorm: `docs/brainstorms/2026-03-16-agent-primitive-brainstorm.md`
- Event-driven Callers (just shipped): PR #279, issue #278
- SDK agent scaffolding: `computer/parachute/models/agent.py`, `api/agents.py`
- Current schema: `computer/modules/daily/module.py` lines 510-560
