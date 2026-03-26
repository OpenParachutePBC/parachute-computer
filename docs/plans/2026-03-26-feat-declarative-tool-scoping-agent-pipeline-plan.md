---
title: Declarative Tool Scoping & Event-Driven Agent Pipeline
status: plan
priority: P3
date: 2026-03-26
labels: [computer, enhancement]
issue: 319
---

# Declarative Tool Scoping & Event-Driven Agent Pipeline

## Overview

Each Parachute agent should declare what MCP tools it needs, with narrow defaults and expandable capabilities. Combined with the existing event dispatch system (#278), this enables composable agent pipelines where one agent's output can trigger the next.

**Depends on**: #318 (scoped tool surfacing) ✅ closed, #278 (event-driven callers) ✅ closed

---

## Current State

### What exists

- **`allowed_tools` on `SandboxTokenContext`** — filters `list_tools()` and `call_tool()` at the MCP bridge boundary
- **Hardcoded profiles** — `CHAT_TOOLS` and `DAILY_TOOLS` frozensets in `mcp_tools.py`
- **`DailyAgentConfig.tools`** — agent-declared tool list, loaded from graph, but **ignored** during sandbox token creation (line 464 always uses `DAILY_TOOLS`)
- **`AgentDefinition.tools`** — model field exists but not wired to filtering
- **`AgentDispatcher`** — event→agent matching with filter support, sequential execution
- **`HookRunner`** — internal event bus for bot connectors, `HookEvent` enum with lifecycle events
- **No chaining** — triggered agents don't fire new events when they mutate data (intentional in #278 v1)

### The gap

1. Agent `tools` config exists but is dead — every sandboxed daily agent gets `DAILY_TOOLS`, every chat session gets `CHAT_TOOLS`
2. No `default` vs `available` distinction — an agent either has a tool or doesn't
3. No context injection — triggered agents don't automatically receive the triggering entity
4. No pipeline chaining — agent A can't trigger agent B

---

## Phases

### Phase 1: Wire agent.tools → allowed_tools (quick win)

**Goal**: Use the agent's declared `tools` field instead of the hardcoded `DAILY_TOOLS` profile.

#### 1a. `daily_agent.py` — Use config.tools for sandboxed agents

**Current** (line 457-464):
```python
from parachute.api.mcp_tools import DAILY_TOOLS
token_ctx = SandboxTokenContext(
    ...
    allowed_tools=DAILY_TOOLS,
)
```

**After**:
```python
from parachute.api.mcp_tools import DAILY_TOOLS, resolve_agent_tools

agent_tools = resolve_agent_tools(config.tools, fallback=DAILY_TOOLS)
token_ctx = SandboxTokenContext(
    ...
    allowed_tools=agent_tools,
)
```

The `resolve_agent_tools()` function:
```python
def resolve_agent_tools(
    declared: list[str] | None,
    fallback: frozenset[str] = frozenset(),
) -> frozenset[str]:
    """Resolve an agent's declared tools to an allowed_tools frozenset.

    If the agent declares tools, use those (intersected with ALL_TOOLS for safety).
    If not, fall back to the profile default.
    """
    if not declared:
        return fallback
    return frozenset(declared) & ALL_TOOLS
```

Where `ALL_TOOLS` is the set of all tool names registered on the MCP server. This prevents agents from declaring nonexistent tools.

#### 1b. Tool guidance for daily agents

`tool_guidance.py` already accepts `allowed_tools`. The daily agent prompt builder should pass the resolved tools so the system prompt only documents available tools. Currently `run_daily_agent()` doesn't inject tool guidance — it relies on the sandbox MCP bridge to filter. This is fine; the prompt just shouldn't mention tools the agent can't use.

#### 1c. Verify existing agent configs

Check that the `transcription-cleanup` agent (and any others seeded in `_seed_builtin_callers()`) have correct `tools` values in the graph. If they declare `["read_entry", "update_entry_content"]` (note-scoped tools), those need to be in `ALL_TOOLS` too.

**Files changed**:
| File | Change |
|------|--------|
| `parachute/api/mcp_tools.py` | Add `ALL_TOOLS` set and `resolve_agent_tools()` |
| `parachute/core/daily_agent.py` | Use `resolve_agent_tools(config.tools)` in `_run_sandboxed()` |

**Risk**: LOW — fallback preserves current behavior when `config.tools` is empty.

---

### Phase 2: Default vs Available tool tiers

**Goal**: Agents declare `default` tools (always visible) and `available` tools (can be unlocked per-instance).

This maps to a UX where:
- A note-tagger agent sees `[update_note]` by default
- But an admin can check a box to also give it `[search_notes, brain_query]` for a specific run

#### 2a. Extend agent schema

Add `available_tools` column to the Agent graph table (alongside existing `tools` which becomes `default_tools` semantically):

```cypher
ALTER TABLE Agent ADD available_tools STRING DEFAULT '[]'
```

Update `DailyAgentConfig`:
```python
class DailyAgentConfig:
    tools: list[str] | None = None            # default tools (always visible)
    available_tools: list[str] | None = None   # unlockable tools
```

#### 2b. Runtime tool expansion

When invoking an agent, `allowed_tools` = `default_tools ∪ expanded_tools` where `expanded_tools ⊆ available_tools`.

For Phase 2, expansion happens via:
- API parameter on `POST /agents/{name}/run` — `expand_tools: ["brain_query"]`
- Caller edit UI checkbox per available tool

#### 2c. Flutter UI

In the Caller edit screen, show two sections:
- **Default tools** — always on (derived from agent config)
- **Available tools** — toggles that expand the default set for this instance

**Files changed**:
| File | Change |
|------|--------|
| `modules/daily/module.py` | Schema migration: `available_tools` column |
| `parachute/core/daily_agent.py` | `DailyAgentConfig.available_tools`, merge logic |
| `parachute/api/mcp_tools.py` | `resolve_agent_tools()` accepts expansion list |
| `app/.../caller_edit_screen.dart` | Available tools UI |

**Risk**: LOW — additive schema change, no behavioral change without opt-in.

---

### Phase 3: Context injection

**Goal**: Triggered agents automatically receive the triggering entity's data in their system prompt.

#### 3a. Context injection in AgentDispatcher

When `AgentDispatcher` invokes a triggered agent, inject the entry data into the prompt:

```python
# In agent_dispatch.py → _invoke_agent()
context_block = f"""
## Triggering Event

Event: {event}
Entry ID: {entry_id}
Entry type: {entry_meta.get('entry_type', 'text')}
Date: {entry_meta.get('date', '')}
"""
```

This is already partially done — `run_triggered_agent()` builds a prompt with entry context. The improvement is making it declarative:

```yaml
agent:
  context:
    inject: [target_note]     # auto-inject the triggering note's content
    include: [recent_notes]   # also inject recent notes for context
```

#### 3b. Context providers

Define context providers that resolve injectable data:

| Provider | Resolves to |
|----------|------------|
| `target_note` | The full content of the triggering Note |
| `recent_notes` | Last N notes (for pattern matching) |
| `agent_history` | This agent's recent run results |
| `brain_entities` | Related brain entities |

Each provider is a function: `async def resolve(entry_id, entry_meta, graph) -> str`

The resolved context is prepended to the system prompt before the agent runs.

**Files changed**:
| File | Change |
|------|--------|
| `parachute/core/agent_dispatch.py` | Read agent's `context.inject`, resolve providers |
| `parachute/core/context_providers.py` | **New**: provider registry + implementations |
| `parachute/core/daily_agent.py` | Accept injected context in `run_triggered_agent()` |

**Risk**: MEDIUM — context size management needed. Providers should have token budgets.

---

### Phase 4: Agent pipeline chaining

**Goal**: An agent's output can trigger the next agent in a chain.

This is the `needs-thinking` part. Two approaches:

#### Option A: Explicit pipeline definition

```yaml
pipeline:
  name: note-processing
  steps:
    - agent: transcription-cleanup
      trigger: note.transcription_complete
    - agent: auto-tagger
      trigger: note.cleanup_complete  # new event, fired after cleanup
    - agent: entity-extractor
      trigger: note.tagged            # fired after tagging
```

Pros: Predictable ordering, easy to debug, no infinite loops.
Cons: Rigid, needs new events for each step.

#### Option B: Event cascading with depth limits

Triggered agents can emit events. The dispatcher tracks depth and stops at a configurable limit.

```python
class AgentDispatcher:
    MAX_CASCADE_DEPTH = 5

    async def dispatch(self, event, entry_id, entry_meta, depth=0):
        if depth >= self.MAX_CASCADE_DEPTH:
            logger.warning(f"Cascade depth limit reached at depth={depth}")
            return []

        # ... invoke agents ...
        # After each agent, check if it emitted events
        for emitted_event in result.get("emitted_events", []):
            await self.dispatch(emitted_event, entry_id, entry_meta, depth=depth+1)
```

Pros: Flexible, emergent pipelines.
Cons: Harder to debug, potential for unexpected chains.

#### Recommendation: Option A for v1

Start with explicit pipelines. The `AgentDispatcher` already runs agents sequentially. Add a simple post-run event emission:

1. Agent runs and produces output
2. If the agent has `post_event` configured (e.g., `note.cleanup_complete`), the dispatcher fires it
3. This re-enters `dispatch()` with the new event, which may match other agents
4. Depth-limited to 5 levels

This is effectively Option B but with explicit `post_event` declarations rather than arbitrary event emission.

**Files changed**:
| File | Change |
|------|--------|
| `parachute/core/agent_dispatch.py` | Add `post_event` support, depth tracking |
| `modules/daily/module.py` | Schema: `post_event` column on Agent table |
| `parachute/core/hooks/events.py` | New events: `note.cleanup_complete`, `note.tagged` |

**Risk**: MEDIUM — loop prevention via depth limit is simple but should be battle-tested.

---

## Implementation Order

| Phase | Effort | Depends on | Ships as |
|-------|--------|-----------|----------|
| **Phase 1** — Wire agent.tools | Small (1-2 hours) | Nothing | Standalone PR |
| **Phase 2** — Default/available tiers | Medium (half day) | Phase 1 | Standalone PR |
| **Phase 3** — Context injection | Medium (half day) | Phase 1 | Standalone PR |
| **Phase 4** — Pipeline chaining | Large (1-2 days) | Phase 1 + Phase 3 | Standalone PR |

Phase 1 is a quick win that unblocks all others. Phases 2-4 are independent of each other.

---

## Files Summary

### New files
| File | Purpose |
|------|---------|
| `parachute/core/context_providers.py` | Context injection providers (Phase 3) |

### Modified files
| File | Phase | Changes |
|------|-------|---------|
| `parachute/api/mcp_tools.py` | 1 | `ALL_TOOLS`, `resolve_agent_tools()` |
| `parachute/core/daily_agent.py` | 1, 2 | Wire `config.tools`, add `available_tools` |
| `parachute/core/agent_dispatch.py` | 3, 4 | Context injection, pipeline chaining |
| `modules/daily/module.py` | 2, 4 | Schema migrations |
| `parachute/core/hooks/events.py` | 4 | New lifecycle events |
| `app/.../caller_edit_screen.dart` | 2 | Available tools UI |

---

## Verification

1. **Phase 1**: Create agent with custom `tools: ["search_memory", "write_card"]` → verify `list_tools()` only returns those two
2. **Phase 2**: Agent with `available_tools: ["brain_query"]` → verify not visible by default, visible when expanded
3. **Phase 3**: Triggered agent with `context.inject: [target_note]` → verify note content appears in prompt
4. **Phase 4**: Agent A with `post_event: "note.cleanup_complete"` → verify Agent B with `trigger_event: "note.cleanup_complete"` fires after A completes
