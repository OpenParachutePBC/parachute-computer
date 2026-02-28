---
title: "feat: Chat episodes in LadybugDB — passive brain growth from every exchange"
type: feat
date: 2026-02-28
modules: brain, chat
priority: P1
depends_on: 129, 130
issue: 143
---

# feat: Chat Episodes in LadybugDB

## Overview

Store every chat exchange as a `Chat_Exchange` entity in LadybugDB, making the brain grow passively from conversation. The bridge agent's existing `observe()` phase writes truncated user message + AI response to the graph after each turn. This enables text search (and later vector search) over conversation history — giving the bridge's `enrich()` phase access to cross-session memory without any additional infrastructure.

## Problem Statement

Today, chat history lives in two disconnected places:
- **SDK JSONL transcripts** — full fidelity but opaque, not searchable by our code
- **SQLite sessions.db** — metadata only (title, summary, message count)

The bridge's `enrich()` can only retrieve deliberately-written `Brain_Entity` nodes. It has no access to what was actually discussed in prior sessions. If you talked about a project last week, the AI won't recall that context unless someone explicitly wrote it to brain.

Meanwhile, the activity log (`vault/Daily/.activity/{date}.jsonl`) captures brief summaries but isn't queryable by the brain's search infrastructure.

## Proposed Solution

Add a `_store_exchange()` call to the bridge's post-turn `observe()`. After Haiku handles session metadata (title, summary, activity log), the bridge writes the exchange directly to LadybugDB using `brain.upsert_entity()`. No Haiku involved — just structured writes.

### Entity Structure

**Chat_Exchange** (one per user+AI round trip):
```
name: "{session_id_short}:ex:{exchange_number}"
entity_type: "Chat_Exchange"
description: "User: {message[:300]} | AI: {response[:500]}"
session_id: full session ID
exchange_number: N
user_message: truncated to 1000 chars
ai_response: truncated to 2000 chars
```

The `description` field is what `brain.search()` matches against, so it packs a useful snippet of both sides. The separate `user_message` and `ai_response` fields allow richer retrieval when needed.

### What's NOT stored

- Tool call details (implementation noise)
- Thinking/reasoning traces
- Full-length messages (truncated instead)
- Trivial exchanges ("thanks", "ok") — skipped via a word-count threshold

### Retrieval

Once exchanges land in the graph, the bridge's existing `enrich()` → `brain.recall()` → `LadybugService.search()` pipeline finds them automatically. No retrieval changes needed in Phase 1.

In Phase 2, we add a filtering layer to separate "conversation history" results from "knowledge graph" results in the context injection, so the AI can distinguish between "you discussed this before" and "this is a stored fact."

## Technical Approach

### Phase 1: Store exchanges (bridge_agent.py)

**New function** in `bridge_agent.py`:

```python
async def _store_exchange(
    session_id: str,
    exchange_number: int,
    message: str,
    result_text: str,
    brain: Any,
) -> None:
    """Write this exchange to LadybugDB for long-term retrieval."""
    # Skip trivial exchanges
    if len(message.split()) < 3 and len(result_text.split()) < 10:
        return

    exchange_name = f"{session_id[:8]}:ex:{exchange_number}"
    user_snippet = message[:300]
    ai_snippet = result_text[:500]
    description = f"User: {user_snippet} | AI: {ai_snippet}"

    await brain.upsert_entity(
        entity_type="Chat_Exchange",
        name=exchange_name,
        attributes={
            "description": description,
            "session_id": session_id,
            "exchange_number": str(exchange_number),
            "user_message": message[:1000],
            "ai_response": result_text[:2000],
        },
    )
```

**Schema columns**: `session_id`, `exchange_number`, `user_message`, `ai_response` are new columns on `Brain_Entity`. They'll be added automatically via `entity_types.yaml` + `sync_schema()`, OR they can be added lazily by `upsert_entity()` if the columns already exist. We should define a `Chat_Exchange` type in `entity_types.yaml` so the columns exist before first write.

**Integration into `observe()`**: At the end of the existing `observe()` function, after the Haiku metadata agent finishes, call `_store_exchange()`. This requires looking up the brain module via `get_registry()`.

```python
# At end of observe(), inside the try block:
try:
    from parachute.core.interfaces import get_registry
    brain = get_registry().get("BrainInterface")
    if brain:
        await _store_exchange(
            session_id=session_id,
            exchange_number=exchange_number,
            message=message,
            result_text=result_text,
            brain=brain,
        )
except Exception as e:
    logger.debug(f"Bridge: exchange store failed (non-fatal): {e}")
```

**`entity_types.yaml` addition**:
```yaml
Chat_Exchange:
  session_id:
    type: text
    description: "Full session ID this exchange belongs to"
  exchange_number:
    type: text
    description: "Exchange number within the session"
  user_message:
    type: text
    description: "Truncated user message (up to 1000 chars)"
  ai_response:
    type: text
    description: "Truncated AI response (up to 2000 chars)"
```

### Phase 2: Filtered context injection (bridge_agent.py)

Update `_format_context_block()` to separate results by entity type. When presenting brain context to the chat agent, distinguish between:

```markdown
## Brain Context

### From your knowledge graph
- **Kevin** (Person): Co-founder at Regen Hub...

### From conversation history
- **a1b2c3d4:ex:3** (Chat_Exchange): User: How should we structure the LVB cohort? | AI: Here's what I'd suggest...
```

This gives the chat agent clear provenance — "you've discussed this before" vs "this is a stored fact."

### Phase 3: Enrich filtering (optional, evaluate after Phase 1)

If `Chat_Exchange` results dominate search results and crowd out knowledge entities, add `entity_type` filtering to `brain.recall()`:

```python
# Option A: Exclude Chat_Exchange from recall by default
results = await svc.search(query=query, num_results=num_results, exclude_types=["Chat_Exchange"])

# Option B: Separate queries — one for knowledge, one for history
knowledge = await svc.search(query=query, entity_type_exclude="Chat_Exchange", num_results=3)
history = await svc.search(query=query, entity_type="Chat_Exchange", num_results=3)
```

This is a future refinement. Start without filtering and see how the search quality holds up.

## Modified Files

| File | Change |
|------|--------|
| `computer/parachute/core/bridge_agent.py` | Add `_store_exchange()`, call it from `observe()` |
| `vault/.brain/entity_types.yaml` | Add `Chat_Exchange` type definition |

That's it for Phase 1. Two files.

## Acceptance Criteria

- [x] Every non-trivial chat exchange creates a `Chat_Exchange` entity in LadybugDB
- [x] Exchanges are searchable via `brain.search()` (text match on description, user_message, ai_response)
- [x] Trivial exchanges (< 3 words from user AND < 10 words from AI) are skipped
- [x] Exchange storage failure never crashes or delays the chat response (fire-and-forget)
- [x] Exchange storage is a no-op when Brain module is not loaded
- [x] `Chat_Exchange` entities visible in the Flutter Brain UI under their type

## Dependencies & Risks

| Risk | Likelihood | Mitigation |
|------|-----------|-----------|
| Exchange entities crowd out knowledge entities in search | Medium | Monitor search results; Phase 3 adds type filtering if needed |
| Column creation fails on first write | Low | Define type in `entity_types.yaml` so `sync_schema()` creates columns at startup |
| High write volume degrades LadybugDB perf | Low | LadybugDB handles concurrent writes via `_write_lock`; one write per exchange is minimal |
| Name collisions (`session_id[:8]:ex:N`) | Very Low | 8 hex chars = 4 billion combinations; collision requires same prefix AND same exchange number |

## Future Direction (not in scope)

This plan is Phase 1 of a larger trajectory:

1. **Chat exchanges in graph** (this plan)
2. **Filtered context injection** — separate "conversation history" from "knowledge" in bridge context
3. **Vector embeddings on exchanges** — LadybugDB VECTOR extension is confirmed working (`INSTALL VECTOR; LOAD EXTENSION VECTOR;`). Add embedding column + HNSW index for semantic search over history
4. **Journal entries as graph nodes** — Daily journal entries ingested as `Journal_Entry` entities (markdown files remain source of truth)
5. **Session nodes** — `Chat_Session` entities linked to their exchanges via relationships
6. **SQLite thinning** — As more content moves to graph, sessions.db shrinks to pure metadata

## References

- #129 — Brain v3 LadybugDB (merged)
- #130 — Brain bridge agent (merged)
- #134 — Brain Phase 4: deduplication, vector search
- #141 — Brain agent for intelligent graph operations
- Bridge agent: `computer/parachute/core/bridge_agent.py`
- LadybugDB service: `computer/modules/brain/ladybug_service.py`
- Brain module interface: `computer/modules/brain/module.py:451-500`
- Orchestrator observe call: `computer/parachute/core/orchestrator.py:1321-1341`
- Schema YAML: `vault/.brain/entity_types.yaml`
