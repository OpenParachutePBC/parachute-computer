---
title: "feat: Rearchitect chat→brain bridge — Message nodes, system writes, agent enrichment"
type: feat
date: 2026-03-23
issue: 326
---

# Rearchitect chat→brain bridge: Message nodes, system writes, agent enrichment

## Overview

Replace Exchange nodes (bundled user+AI) with individual Message nodes written by the system immediately, then enriched asynchronously by a `process-chat` agent. User-authored content becomes a first-class graph node the moment it's sent — never contingent on a post-processor succeeding.

## Problem Statement

Today the bridge agent (Haiku) runs post-turn and creates Exchange nodes that bundle `user_message` + `ai_response`. Three critical problems:

1. **User content lost on bridge failure** — if bridge_observe() errors or skips trivial exchanges (< 3 words), nothing is written to the graph
2. **Wrong granularity** — Exchange bundles two distinct acts (human thought + machine response) into one node, losing the ability to query them independently
3. **Assumes call-and-response** — as conversations become more stream-like (multiple human messages before machine responds, interrupted responses), the Exchange model breaks down

## Proposed Solution

### New `Message` node type

```
Message {
  message_id:    STRING (PK)     — "{session_id[:8]}:msg:{sequence}"
  session_id:    STRING           — parent Chat session (Parachute session ID)
  role:          STRING           — "human" | "machine"
  content:       STRING           — full text (see content rules below)
  status:        STRING           — "complete" | "interrupted" | "error" | "pending"
  sequence:      INT64            — order within session (1, 2, 3, ...)

  // Machine-specific
  tools_used:    STRING           — JSON: tool names + param keys (lightweight)
  thinking:      STRING           — thinking blocks concatenated (null for sandboxed)

  // Enrichment (set by process-chat agent, nullable)
  description:   STRING           — search-optimized summary
  context:       STRING           — session state snapshot at time of message

  created_at:    STRING
  updated_at:    STRING
  metadata_json: STRING
}
```

Relationship: `Chat -[HAS_MESSAGE]-> Message`

### Content rules

| Role | What goes in `content` |
|------|----------------------|
| **human** | Full text the user sent |
| **machine** | All text blocks concatenated (including mid-stream text, not just final `done` text). Tool request/response payloads excluded (too large). |

**Thinking blocks** → dedicated `thinking` field. Null for sandboxed sessions (Docker doesn't expose them).

**Tool summary** → `tools_used` field as JSON: `[{"name": "Read", "file_path": "..."}, ...]`. Names + short param previews, not full payloads. Reuses existing `_summarize_tool_calls()` / `_pick_preview()` from bridge_agent.py.

### System writes in orchestrator

Both `_run_trusted()` and `_run_sandboxed()` write Messages via a shared function. No divergence between trust paths.

```python
async def write_turn_messages(
    graph: BrainService,
    session: Session,
    human_content: str,
    machine_content: str,
    tools_used: list[dict],
    thinking: str | None,
    status: str,
) -> tuple[str, str]:  # returns (human_msg_id, machine_msg_id)
```

**Write points in the orchestrator:**

| When | What | Where in code |
|------|------|---------------|
| After event loop completes (both paths) | Write human Message + machine Message in one call | Replace `bridge_observe()` call site at lines 1360-1389 (trusted) and 1819-1852 (sandboxed) |

Note: We write both messages at turn end (not human message at turn start) because the session_id may not be finalized until the SDK responds. The human message `created_at` timestamp can still be captured early.

**Chat node lifecycle:** Lazy-created on first human Message write (same pattern as current `_store_exchange`, but moved to the system write path).

### process-chat agent replaces bridge_observe

The current `bridge_observe()` does two things:
1. **Session metadata updates** (title, summary) — via Haiku structured output
2. **Exchange storage** — writes to graph

With Message nodes written by the system, the bridge agent's job shrinks to **enrichment only**:

- Trigger: async after `write_turn_messages()` completes
- Reads the new Message nodes (already slimmed down)
- Adds `description` to both messages (search-optimized summary)
- Updates Chat node title/summary
- **Model: Sonnet** (Haiku is too weak for quality summaries)
- Follows `process-note` / `process-day` naming pattern (ref #323)

## Acceptance Criteria

- [ ] Message node type exists in brain graph schema
- [ ] Human and machine Messages written automatically by orchestrator (both trusted and sandboxed paths)
- [ ] Messages written even when AI response is interrupted/errored (with appropriate status)
- [ ] Machine Messages include all text blocks (not just final), tool summary, and thinking blocks
- [ ] Chat node lazy-created on first human Message write
- [ ] process-chat agent enriches Message nodes with description
- [ ] process-chat updates session title/summary (as bridge does today)
- [ ] All agents use Sonnet (not Haiku)
- [ ] search_memory, search_chats, get_chat, get_exchange updated to query Message nodes
- [ ] MCP tools (vault_tools.py) updated for Message shape
- [ ] Exchange nodes dropped from schema
- [ ] Old bridge agent code removed
- [ ] Existing unit tests pass or are updated

## Technical Considerations

### Files to modify

**Core changes (Phase 1-2):**

| File | Change |
|------|--------|
| `parachute/db/brain_chat_store.py` | Add `Message` node schema, `HAS_MESSAGE` rel, `write_turn_messages()` method |
| `parachute/core/orchestrator.py` | Replace `bridge_observe()` calls (~lines 1360-1389, 1819-1852) with `write_turn_messages()` + async process-chat trigger |
| `parachute/core/bridge_agent.py` | Refactor: extract tool summary helpers, remove `_store_exchange()`, replace `observe()` with process-chat trigger |

**process-chat agent (Phase 3):**

| File | Change |
|------|--------|
| `parachute/db/brain_chat_store.py` | Add `process-chat` to `AGENT_TEMPLATES`, update `seed_builtin_agents()` |
| `parachute/core/daily_agent.py` | Ensure agent runner supports process-chat trigger pattern (may already work) |
| `parachute/core/daily_agent_tools.py` | Add tools for reading/enriching Message nodes |

**Search/API updates (Phase 4):**

| File | Change |
|------|--------|
| `parachute/core/vault_tools.py` | Update `search_memory()`, `search_chats()`, `get_chat()`, `get_exchange()` → `get_message()` to query Message nodes |
| `parachute/api/brain.py` | Update REST endpoints: `/chats/{id}`, `/chats/search`, `/exchanges` → `/messages`, `/memory` |
| `parachute/api/mcp_tools.py` | Update MCP tool dispatch for renamed/updated tools |

**Cleanup (Phase 4):**

| File | Change |
|------|--------|
| `parachute/db/brain_chat_store.py` | Remove Exchange schema, HAS_EXCHANGE rel |
| `parachute/core/bridge_agent.py` | Remove or archive entirely |

**Flutter (Phase 4, if needed):**

| File | Change |
|------|--------|
| `app/lib/features/chat/models/bridge_run.dart` | Update or remove Exchange-shaped models |
| `app/lib/features/chat/providers/chat_message_providers.dart` | Update any Exchange references |
| `app/lib/features/chat/widgets/bridge_session_viewer_sheet.dart` | Update or remove |

### Sequence numbering

`sequence` is an independent INT64 counter per session. Derived from the current `message_count` at write time:
- Human message sequence = `message_count + 1`
- Machine message sequence = `message_count + 2`

This is consistent because `message_count` is incremented by 2 per turn (already the case). The `message_count` field on Session stays as-is for Flutter backward compat.

### Message ID format

Deterministic for idempotent upserts: `"{session_id[:8]}:msg:{sequence}"`

Example: `"a1b2c3d4:msg:1"` (human), `"a1b2c3d4:msg:2"` (machine)

### Thinking block collection

`_run_trusted()` currently yields `ThinkingEvent` but doesn't accumulate thinking text. Add a `thinking_blocks: list[str]` accumulator alongside `text_blocks`, populated at the `block_type == "thinking"` branch (~line 1149).

Sandboxed path: Docker container events don't include thinking blocks, so `thinking` will be null. This is a natural trust boundary limitation.

### Bridge session continuity

The current bridge maintains a `bridge_session_id` for Haiku context across turns. The process-chat agent will use the standard `Agent.sdk_session_id` + `memory_mode: persistent` pattern instead (same as process-day). This is cleaner — no special-case session tracking on the Chat node.

Fields to remove from Chat schema eventually: `bridge_session_id`, `bridge_context_log`.

### Migration strategy

**Clean break.** Drop all Exchange nodes and HAS_EXCHANGE relationships. The exchange data hasn't been heavily relied on. A `DROP TABLE Exchange` + `DROP TABLE HAS_EXCHANGE` in a migration step is simplest.

Keep the Exchange schema temporarily during development (Phase 1-2 write both Exchange and Message nodes for comparison), then drop in Phase 4.

## Implementation Phases

### Phase 1: Schema + system writes
1. Add `Message` node table to `BrainChatStore.ensure_schema()`
2. Add `HAS_MESSAGE` rel table (`Chat` → `Message`)
3. Implement `write_turn_messages()` on BrainChatStore
4. Add thinking block accumulator to `_run_trusted()` event loop
5. Call `write_turn_messages()` from both orchestrator paths (after event loop, replacing bridge_observe call site)
6. Keep `bridge_observe()` running in parallel during this phase (dual-write for safety)
7. Lazy-create Chat node on first human Message write

### Phase 2: Content extraction + quality
8. Verify `result_text` includes all mid-stream text blocks (it should — `text_blocks` accumulation)
9. Tool summary: reuse `_summarize_tool_calls()` from bridge_agent.py, store as JSON
10. Thinking: concatenate thinking_blocks into `thinking` field
11. Status tracking: map exit conditions (normal→complete, interrupt→interrupted, error→error, timeout→interrupted)
12. Write tests for `write_turn_messages()` — various scenarios (normal, interrupted, no content, sandboxed)

### Phase 3: process-chat agent
13. Create `process-chat` agent template in `AGENT_TEMPLATES` (Sonnet, trigger: post-turn)
14. Implement process-chat trigger in orchestrator (replaces bridge_observe async task)
15. process-chat reads new Message nodes, adds `description`, updates Chat title/summary
16. Move all existing agents to Sonnet (update `daily-reflection` and `post-process` templates)
17. Remove dual-write — stop calling old `bridge_observe()`

### Phase 4: Search migration + cleanup
18. Update `vault_tools.py`: `search_memory()` queries `Message.content` instead of `Exchange.user_message`/`Exchange.ai_response`
19. Update `vault_tools.py`: `search_chats()` matches against `Message.content` + `Message.description`
20. Update `vault_tools.py`: `get_chat()` returns Messages instead of Exchanges
21. Rename `get_exchange()` → `get_message()` in vault_tools, MCP tools, and REST API
22. Update `api/brain.py` endpoints
23. Update `api/mcp_tools.py` dispatch
24. Drop Exchange node table and HAS_EXCHANGE rel table
25. Remove `bridge_agent.py` (or archive the tool-summary helpers if reused)
26. Remove `bridge_session_id` / `bridge_context_log` from Chat schema
27. Update Flutter models if any directly reference Exchange shape

## Dependencies & Risks

| Risk | Mitigation |
|------|------------|
| Dual-write period adds complexity | Phase 1-2 only; remove once Message writes are verified |
| process-chat on Sonnet is more expensive than Haiku | Sonnet cost per enrichment call is low; quality gain is worth it |
| Search query performance changes with Message vs Exchange | Message.content is typically shorter than Exchange.ai_response (no full AI dump); CONTAINS queries should be faster |
| Flutter breaking changes | Exchange references are minimal (4 files); bridge viewer sheet may be removable |
| Thinking blocks add storage size | Only stored for trusted sessions; nullable field, no impact if empty |

## References

- Issue: #326
- Related: #323 (generalize agents), #322 (persistent cards), #324 (daily agent refinement)
- Original bridge brainstorm: `docs/brainstorms/2026-02-27-brain-bridge-agent-brainstorm.md`
- External research: Graphiti EpisodeNode pattern, OpenAI Messages API, Matrix event model
