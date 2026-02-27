---
title: "feat: Brain bridge agent — ambient context enrichment"
type: feat
date: 2026-02-27
issue: 130
modules: brain, chat
priority: P2
depends_on: 129
status: plan
---

# feat: Brain Bridge Agent — Ambient Context Enrichment

## Overview

A Haiku pre-hook that runs before the chat agent on every user message. It makes a fast intent judgment — enrich with brain context, step back for intentional brain queries, or pass through — and injects relevant context into the chat agent's system prompt. After the chat agent responds, it evaluates whether anything significant was said and writes it back to brain.

This is Phase 3 of Brain. Phase 1+2 (#129, now merged) built the LadybugDB backend and Flutter UI. This phase makes brain knowledge **ambient in conversation** — you don't have to explicitly ask the chat agent to check your brain. It just knows.

## Depends On

- **#129** (Brain v3 — LadybugDB backend + Flutter UI) must be complete and on `main`

## Problem Statement

Without a bridge agent, brain is purely reactive: you have to explicitly ask the chat agent to query it, or the chat agent has to guess when to use its MCP brain tools. Two failure modes:

1. **Under-enrichment** — "I need to finish that letter by Friday" — the chat agent has no reason to query brain, but the bridge knows from conversation history there's relevant context (what letter? what project?).

2. **Over-enrichment** — "Find people in my graph who work on regenerative tech" — if the bridge pre-loaded partial context, it would interfere with the chat agent's deeper intentional query. The bridge should step back.

## Proposed Solution

### Three-Mode Judgment

The bridge agent (Haiku) reads:
- The incoming user message
- `session.summary` (running conversation summary, maintained by curator)
- A log of brain context already loaded this session

And makes one of three judgments:

| Mode | Trigger | Action |
|------|---------|--------|
| **Enrich** | Vague references the user expects chat to handle | Translate to brain queries, inject context into system prompt |
| **Step back** | User explicitly wants to work with brain | Load minimal orientation only, let chat agent query directly |
| **Pass through** | Normal conversation, no brain involvement | Do nothing (saves tokens and latency) |

### Post-Turn Write-Back

After each exchange, bridge evaluates (fire-and-forget, like curator):
- Did anything significant happen? (commitment, decision, new relationship, realization)
- If yes: formulate specific `brain.upsert_entity()` calls
- Update the bridge context log for the session

### What's Deferred (Phase 4+)

This plan does **not** include:
- Semantic/vector search (LadybugDB HNSW — Phase 4)
- Entity resolution cascade with alias tracking (Phase 4)
- `invalidate()` for temporal edges (Phase 4)
- `curate()` / curation queue UI (Phase 5)
- `evolve_schema()` and Assertion type (Phase 5)
- Full NL `remember()` with entity resolution (Phase 4)

Phase 3 `recall` = `brain.search()` with structured output. Phase 3 `remember` = direct `brain.upsert_entity()` calls formulated by Haiku.

---

## Technical Approach

### Architecture

```
User message
  ↓
bridge_agent.enrich()  ← NEW: awaited in orchestrator.run_streaming()
  - Reads message + session.summary + bridge_context_log
  - Haiku judges: enrich / step back / pass through
  - If enriching: calls brain.search() with translated queries
  - Returns context string (or None for step-back/pass-through)
  ↓
_build_system_prompt() injects bridge context into append_parts
  ↓
query_streaming() — chat agent (Sonnet/Opus) runs with enriched context
  ↓
Response delivered to user
  ↓
asyncio.create_task(bridge_agent.writeback())  ← NEW: fire-and-forget
  - Haiku judges: anything significant to store?
  - If yes: calls brain.upsert_entity() directly
  - Updates bridge_context_log on session
```

### Injection Point in `orchestrator.py`

Between `_build_system_prompt()` (~line 383) and `query_streaming()`:

```python
# computer/parachute/core/orchestrator.py

# After _build_system_prompt(), before query_streaming():
brain = get_registry().get("BrainInterface")
if brain and message:
    from parachute.core.bridge_agent import enrich as bridge_enrich
    bridge_ctx = await bridge_enrich(
        message=message,
        session_summary=session.summary,
        brain=brain,
        claude_token=self.settings.claude_code_oauth_token,
        vault_path=self.vault_path,
    )
    if bridge_ctx:
        effective_prompt = (effective_prompt or "") + bridge_ctx
```

Post-turn write-back (after existing curator call at ~line 1300):

```python
# computer/parachute/core/orchestrator.py
if brain and message and result_text:
    from parachute.core.bridge_agent import writeback as bridge_writeback
    asyncio.create_task(
        bridge_writeback(
            session_id=final_session_id,
            message=message,
            result_text=result_text,
            brain=brain,
            claude_token=self.settings.claude_code_oauth_token,
            database=self.database,
        )
    )
```

### New Files

```
computer/parachute/core/bridge_agent.py    # enrich() + writeback()
```

Modeled exactly on `curator.py`. Key differences from curator:
- `enrich()` is **awaited** (not fire-and-forget) — result is needed before chat agent starts
- `enrich()` calls `brain.search()` directly (no MCP subprocess needed for reads)
- `writeback()` calls `brain.upsert_entity()` directly (trusted internal module)
- No separate MCP server needed — brain reads/writes go through the InterfaceRegistry

### Modified Files

```
computer/parachute/core/orchestrator.py    # inject enrich() + writeback()
computer/parachute/models/session.py       # add bridge_context_log: Optional[str]
computer/parachute/db/database.py          # migration: add bridge_context_log column
computer/modules/brain/module.py           # fix latent bug in search_brain_context()
computer/modules/chat/module.py            # fix latent bug: await brain.search()
app/lib/features/chat/                     # subtle brain context indicator in UI
```

---

## Implementation Phases

### Phase 1: Fix Latent Bug + BrainInterface Foundation

**Goal:** `brain.search()` is correctly awaited everywhere before we add the bridge.

#### `computer/modules/chat/module.py`

```python
# CURRENT (broken — returns coroutine, not result):
def search_brain_context(self, query: str) -> list[dict]:
    brain = self._get_brain()
    if not brain:
        return []
    return brain.search(query)   # ← bug: async not awaited

# FIX (make async):
async def search_brain_context(self, query: str) -> list[dict]:
    brain = self._get_brain()
    if not brain:
        return []
    return await brain.search(query)
```

Update any callers of `search_brain_context()` to `await` it.

#### `computer/modules/brain/module.py` — `recall()` method

Add a `recall()` method to `BrainModule` as a structured wrapper over `search()`:

```python
async def recall(self, query: str, num_results: int = 5) -> dict:
    """
    Structured context retrieval for bridge agent use.
    Returns a bundle ready for system prompt injection.
    """
    svc = await self._ensure_service()
    results = await svc.search(query=query, num_results=num_results)
    return {
        "query": query,
        "results": results,
        "count": len(results),
    }
```

### Phase 2: Session Schema + Bridge Context Log

#### `computer/parachute/models/session.py`

```python
# Add to Session model:
bridge_context_log: Optional[str] = None   # JSON: list of {query, type, turn_number}
```

#### `computer/parachute/db/database.py`

In `initialize_schema()`, add migration for sessions table (current schema v14):

```sql
-- schema v15:
ALTER TABLE sessions ADD COLUMN bridge_context_log TEXT DEFAULT NULL;
```

### Phase 3: Bridge Agent Core

#### `computer/parachute/core/bridge_agent.py`

```python
"""
Brain Bridge Agent — ambient context enrichment pre-hook.

Runs before the chat agent on every user message.
Makes an intent judgment (Haiku) and optionally injects
brain context into the chat agent's system prompt.

Post-turn write-back runs as fire-and-forget (like curator).
"""

BRIDGE_ENRICH_PROMPT = """
You are a context enrichment assistant. Evaluate the user message and conversation summary below.

Make ONE judgment:
- ENRICH: The user is making a request the chat agent will handle. You should translate vague references
  into specific brain search queries to load relevant context.
- STEP_BACK: The user explicitly wants to query or explore their brain/knowledge graph directly.
  The chat agent will do this intentionally. Do not pre-load context.
- PASS_THROUGH: Normal conversation with no brain involvement needed.

If ENRICH: provide 1-3 short keyword search queries (not full sentences — keyword phrases work best).
If STEP_BACK or PASS_THROUGH: provide no queries.

Respond in JSON:
{"judgment": "enrich|step_back|pass_through", "queries": ["query1", "query2"]}
"""

BRIDGE_WRITEBACK_PROMPT = """
You are a knowledge graph curator. Review the exchange below and decide:
1. Was anything significant said? (commitment, decision, new relationship, fact about a person/project)
2. If yes: what should be stored in the knowledge graph?

Respond in JSON:
{"should_store": true|false, "entities": [{"entity_type": "...", "name": "...", "description": "..."}]}

Only store clear, durable facts. Do not store conversational filler.
"""

async def enrich(message, session_summary, brain, claude_token, vault_path) -> str | None:
    """
    Pre-hook: runs before the chat agent.
    Returns a context string to inject into the system prompt, or None.
    """
    # ... Haiku call with BRIDGE_ENRICH_PROMPT
    # ... parse JSON response
    # ... if enrich: await brain.search() for each query
    # ... format results as ## Brain Context markdown block
    # ... return formatted block or None

async def writeback(session_id, message, result_text, brain, claude_token, database) -> None:
    """
    Post-turn: fire-and-forget after chat agent response.
    Stores significant facts to brain, updates bridge_context_log.
    """
    # ... Haiku call with BRIDGE_WRITEBACK_PROMPT
    # ... parse JSON response
    # ... if should_store: await brain.upsert_entity() for each entity
    # ... append to session.bridge_context_log
```

**Key implementation details:**
- `use_claude_code_preset=False` (same as curator)
- `setting_sources=[]`, `tools=[]`, `permission_mode="bypassPermissions"`
- `model="claude-haiku-4-5-20251001"`
- Guarded: `if brain is None: return None` — degrades gracefully when brain module absent
- `enrich()` uses direct `await brain.search()` calls — no MCP subprocess for reads
- `writeback()` uses direct `await brain.upsert_entity()` calls — no MCP subprocess for writes
- Wrap Haiku call in `try/except` — a bridge failure must never crash the main chat flow
- Short timeout: 3s for enrich (latency-sensitive), 10s for writeback (fire-and-forget)

### Phase 4: Context Formatting

The bridge context injected into the system prompt:

```markdown
## Brain Context

The following context was retrieved from your knowledge graph based on the current conversation.

### From query: "letter Flock Safety"
- **Flock Safety Contract Letter** (document): Draft letter to Flock Safety re: contract renewal...
- **Flock Safety** (company): AI-powered license plate recognition company...

_Context loaded: 2 results from 1 query._
```

Rules:
- Max 1500 tokens of brain context to avoid overwhelming the context window
- Only include `name`, `entity_type`, and `description` — not internal fields
- Include source query so the chat agent understands provenance
- If bridge is `step_back`: inject a minimal note: `_Brain context: stepping back — you are directly querying your knowledge graph._`

### Phase 5: Flutter UI Indicator

A subtle indicator in the chat UI showing when brain context was loaded.

#### `app/lib/features/chat/` — turn indicator

When a message response contains bridge-injected context (indicated by a new `brain_context_loaded: bool` field in the SSE `PromptMetadataEvent`), show a small indicator:

```
[user message bubble]
  🧠 2 brain contexts loaded  ← subtle, collapsible
[assistant response bubble]
```

Implementation:
- Add `brain_context_loaded: bool` and `brain_context_count: int` to `PromptMetadataEvent` (Python server)
- Parse in Flutter `ChatMessageModel` / `PromptMetadataMessage`
- Render as a subtle chip above the assistant response bubble

---

## Acceptance Criteria

### Functional

- [ ] Bridge agent runs on every chat message when Brain module is loaded
- [ ] Bridge correctly identifies "enrich" vs "step back" vs "pass through" for representative examples
- [ ] Enriched context appears in the chat agent's system prompt (verifiable in logs)
- [ ] Post-turn write-back stores significant facts to brain without blocking the response
- [ ] Bridge failure (network error, Haiku timeout) never crashes or delays the chat response
- [ ] Bridge is a no-op when Brain module is not loaded (graceful degradation)
- [ ] `recall()` method on BrainModule returns structured context bundle
- [ ] Latent bug fixed: `brain.search()` is properly awaited in `chat/module.py`

### Performance

- [ ] `enrich()` adds ≤500ms to message latency on the fast path (Haiku + 1-2 brain queries)
- [ ] `enrich()` adds 0ms when judgment is `pass_through` (short-circuit before Haiku call if message < 5 words)
- [ ] `writeback()` is non-blocking (fire-and-forget via `asyncio.create_task`)

### Quality

- [ ] Bridge context injects ≤1500 tokens to avoid context window pressure
- [ ] Bridge context includes query provenance (which query retrieved which results)
- [ ] `bridge_context_log` on session captures what was loaded/stored per turn (for debugging)
- [ ] Logs show bridge judgment decisions at DEBUG level

### Flutter

- [ ] Brain context indicator shows when context was loaded, hidden when not
- [ ] Indicator is subtle, not disruptive to chat flow
- [ ] Collapsible to show which queries were run

---

## Dependencies & Risks

| Risk | Likelihood | Mitigation |
|------|-----------|-----------|
| Haiku latency spikes add noticeable delay | Low | 3s timeout + short-circuit for very short messages |
| Bridge over-enriches and clutters context window | Medium | Token cap (1500), max 3 queries per turn |
| Bridge writes incorrect facts on writeback | Medium | Conservative prompt — only store "clear durable facts" |
| `brain.search()` is slow on large graph | Low | Substring search is fast; limit `num_results=5` |
| Haiku JSON parsing fails | Medium | Wrap in `try/except`, log + return `None` on parse failure |
| Context injection breaks existing chat tests | Low | Guard behind `if brain is not None` — no-op without brain |

---

## References

### Internal

- Brainstorm: `docs/brainstorms/2026-02-27-brain-bridge-agent-brainstorm.md`
- Brain v3 plan: `docs/plans/2026-02-26-feat-brain-v3-ladybugdb-plan.md`
- Curator pattern: `computer/parachute/core/curator.py` (exact template)
- Injection point: `computer/parachute/core/orchestrator.py:383` (between `_build_system_prompt` and `query_streaming`)
- BrainInterface: `computer/modules/brain/module.py:461` (`search`, `upsert_entity`)
- InterfaceRegistry: `computer/parachute/core/interfaces.py`
- Session model: `computer/parachute/models/session.py`
- DB migrations: `computer/parachute/db/database.py` (~line 250)
- Latent bug: `computer/modules/chat/module.py` (`search_brain_context` doesn't await)

### Related Issues

- #129 — Brain v3 LadybugDB (Phase 1+2, prerequisite) — merged in PR #131
- #130 — This issue (Phase 3)
- Phase 4 (future): Entity resolution cascade, semantic search, alias tracking
- Phase 5 (future): Assertion type, curation queue, `evolve_schema()`
