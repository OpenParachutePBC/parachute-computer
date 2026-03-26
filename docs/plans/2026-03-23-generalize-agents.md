---
issue: 323
date: 2026-03-23
status: plan
---

# Plan: Generalize agents — unified runner with composable tools

## What We're Solving

Tools are locked to runner functions, not composable from config. `daily_agent_tools.py` creates all day tools as a monolith. `triggered_agent_tools.py` creates all note tools as a monolith. If a future agent needs tools from both, you're stuck. Adding the chat exchange agent would mean copy-pasting a third runner.

## What We Want After

An agent config in the DB says `tools: ["read_this_note", "read_days_notes", "add_tags"]` and gets exactly those tools, regardless of "agent type." Adding a new agent is a DB record. Adding a new tool is one factory function.

## Tool Renames

Clearer names that say what they do:

| Current | New | Why |
|---------|-----|-----|
| `read_journal` | `read_days_notes` | Reads all notes for a date, not just "journal" |
| `read_entry` | `read_this_note` | Reads the specific note this agent is processing |
| `update_entry_content` | `update_this_note` | Updates the specific note |
| `update_entry_tags` | `update_note_tags` | Sets tags on the note |
| `update_entry_metadata` | `update_note_metadata` | Sets metadata on the note |
| `read_chat_log` | `read_days_chats` | Reads chat logs for a date |
| `update_entry` | (remove — duplicate of update_entry_content in daily_agent_tools) | |

Keep as-is: `read_recent_journals`, `read_recent_sessions`, `write_card`.

## Phase 1: Tool Factory Dict + `bind_tools()`

**New file: `parachute/core/agent_tools.py`** (~60 lines)

A plain dict mapping tool names to `(factory_fn, required_scope_keys)`. No decorators, no classes.

```python
# agent_tools.py
TOOL_FACTORIES: dict[str, tuple[Callable, frozenset[str]]] = {}

def bind_tools(config, scope, graph):
    """Create tools for an agent run. Validates scope has required keys."""
    tools = []
    for name in config.tools:
        factory, required = TOOL_FACTORIES[name]
        missing = required - scope.keys()
        if missing:
            raise ValueError(f"Tool '{name}' needs {missing} in scope")
        tools.append(factory(graph, scope, config.name))
    return tools, create_sdk_mcp_server(name=f"agent_{config.name}", ...)
```

**Modified: `daily_agent_tools.py`** — break monolithic `create_daily_agent_tools()` into individual factories, register each:

```python
def _make_read_days_notes(graph, scope, agent_name):
    date = scope["date"]
    @tool("read_days_notes", "Read all notes for a specific date.", {"date": str})
    async def read_days_notes(args): ...
    return read_days_notes

TOOL_FACTORIES["read_days_notes"] = (_make_read_days_notes, frozenset({"date"}))
TOOL_FACTORIES["read_days_chats"] = (_make_read_days_chats, frozenset({"date"}))
TOOL_FACTORIES["read_recent_journals"] = (_make_read_recent_journals, frozenset())
TOOL_FACTORIES["read_recent_sessions"] = (_make_read_recent_sessions, frozenset())
TOOL_FACTORIES["write_card"] = (_make_write_card, frozenset())
```

**Modified: `triggered_agent_tools.py`** — same pattern:

```python
TOOL_FACTORIES["read_this_note"] = (_make_read_this_note, frozenset({"entry_id"}))
TOOL_FACTORIES["update_this_note"] = (_make_update_this_note, frozenset({"entry_id"}))
TOOL_FACTORIES["update_note_tags"] = (_make_update_note_tags, frozenset({"entry_id"}))
TOOL_FACTORIES["update_note_metadata"] = (_make_update_note_metadata, frozenset({"entry_id"}))
```

The tool implementations stay in their respective files — day tools in `daily_agent_tools.py`, note tools in `triggered_agent_tools.py`. They just register into the shared dict.

## Phase 2: Unified Runner

**Modified: `daily_agent.py`** — add `run_agent()`, convert old functions to thin wrappers.

`run_agent(vault_path, agent_name, scope, force=False, trigger="manual")`:

1. Load config from graph
2. Load agent state (sdk_session_id, memory_mode, etc.)
3. Pre-checks driven by scope keys:
   - `"date"` in scope + `"read_days_notes"` in tools → check notes exist for date
   - `"entry_id"` in scope → check entry exists
   - `"date"` in scope → dedup check (last_processed_date)
4. Build system prompt — substitute `{date}`, `{entry_id}`, `{event}`, `{user_name}`, `{user_context}` from scope + profile
5. Build user prompt from scope context
6. Create tools via `bind_tools(config, scope, graph)`
7. Write initial Card (only if `"write_card"` in config.tools)
8. Create AgentRun (with scope stored as JSON)
9. Route execution — sandbox vs direct (existing `_run_sandboxed` / `_run_direct`)
10. Record result

**Thin wrappers** (zero changes to callers):

```python
async def run_daily_agent(vault_path, agent_name, date=None, force=False, trigger="manual", **kw):
    if date is None:
        date = (datetime.now().astimezone() - timedelta(days=1)).strftime("%Y-%m-%d")
    return await run_agent(vault_path, agent_name, {"date": date}, force=force, trigger=trigger)

async def run_triggered_agent(vault_path, agent_name, entry_id, event):
    return await run_agent(vault_path, agent_name, {"entry_id": entry_id, "event": event}, trigger="event")
```

**No changes needed** in scheduler.py, agent_dispatch.py, or modules/daily/module.py.

## Phase 3: Rename Built-in Agents

**Modified: `brain_chat_store.py`**

Update templates:
- `daily-reflection` → `process-day` (template_version bump to `2026-03-23`)
- `post-process` → `process-note` (template_version bump)

Update tool names in templates:
- process-day: `["read_days_notes", "read_days_chats", "read_recent_journals"]`
- process-note: `["read_this_note", "update_this_note"]`

Migration in `seed_builtin_agents()`:
- If old agent not user-modified → rename node in graph
- If user-modified → leave old, create new from template
- Add old names to retired list

**Modified: `scheduler.py`** — update legacy name mapping in `trigger_job_now()`.

**Modified: `brain_chat_store.py`** — add `scope` column to AgentRun schema.

## Phase 4: Tests

- **`test_agent_tools.py`** (new): bind_tools with valid scope, missing scope key → ValueError, unknown tool → KeyError, all registered tools have valid factories
- **Extend existing tests**: verify wrappers construct correct scope, verify renamed agents seed correctly
- Run full suite

## Implementation Order

1. Phase 1 (tool registry) — commit when tests pass
2. Phase 2 (unified runner) — commit when tests pass
3. Phase 3 (rename) — commit when tests pass
4. Phase 4 (additional tests) — commit

## Files Summary

| File | Phase | Change |
|------|-------|--------|
| `parachute/core/agent_tools.py` | 1 | **New** — TOOL_FACTORIES dict + bind_tools() |
| `parachute/core/daily_agent_tools.py` | 1 | Break into individual factories, register |
| `parachute/core/triggered_agent_tools.py` | 1 | Break into individual factories, register |
| `parachute/core/daily_agent.py` | 2 | Add run_agent(), thin wrappers |
| `parachute/db/brain_chat_store.py` | 3 | Rename templates, migration, scope on AgentRun |
| `parachute/core/scheduler.py` | 3 | Update legacy name mapping |
| `tests/unit/test_agent_tools.py` | 4 | **New** |

## Not In Scope

- Chat exchange agent (will be trivial after this — just new tool factories + DB record)
- Declarative agent YAML configs (#319)
- Suggested edits (#325)
- Flutter UI changes for renamed agents
