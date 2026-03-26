---
title: "Daily reflection agent: two-stage summarize → reflect"
type: feat
date: 2026-03-25
issue: 351
---

# Daily Reflection Agent Redesign

Two-stage architecture: sub-agents summarize each chat session, then the reflection agent synthesizes across summaries + journals + recent reflection cards.

## Problem Statement

The daily reflection agent has weak signal from chats. `read_days_chats` reads from a dead filesystem path (`Daily/chat-log/`). Messages have been in the graph for months. Even fixing the path wouldn't help — dumping raw transcripts into the reflection agent's context is noisy and expensive.

## Proposed Solution

### Architecture

```
Reflection Agent (process-day, Sonnet)
  │
  ├─ read_days_chats(date)         → lightweight session list from graph
  │
  ├─ summarize_chat(session_id)    → for each session:
  │     └─ Sub-agent (Haiku)         reads full transcript from graph
  │           └─ returns:             1. session context (persisted to session.summary)
  │                                   2. today's activity (returned to parent)
  │
  ├─ read_days_notes(date)         → journal entries (already works)
  │
  ├─ read_recent_cards(days, type) → last 7 days of reflection cards
  │
  └─ write_card(date, content,     → writes reflection card
  │     card_type="reflection")
```

### Phase 1: Rewrite `read_days_chats` (graph-backed)

**File:** `computer/parachute/core/daily_agent_tools.py`

Replace the filesystem-based implementation with a graph query. Return a lightweight session list — no raw messages.

```python
# Query: sessions with messages on the target date
MATCH (s:Chat)-[:HAS_MESSAGE]->(m:Message)
WHERE m.created_at >= $date_start AND m.created_at < $date_end
  AND s.module = 'chat'
WITH s, count(m) AS msg_count,
     min(m.created_at) AS first_msg, max(m.created_at) AS last_msg
RETURN s.session_id, s.title, s.summary, msg_count, first_msg, last_msg
ORDER BY first_msg ASC
```

**Returns to agent:** Session ID, title, message count, time range, existing summary (if any). Agent uses this to decide which sessions to summarize.

### Phase 2: New `summarize_chat` tool

**File:** `computer/parachute/core/daily_agent_tools.py`

New tool factory: `_make_summarize_chat`. Requires `date` in scope.

**Mechanic:** The tool itself calls `sdk_query()` directly — no HTTP, no separate process. It:

1. Reads all messages for the session from the graph via Cypher
2. Identifies which messages are from the target date (using `created_at` timestamps)
3. Constructs a prompt for a Haiku sub-agent with:
   - The full transcript (for context)
   - Clear instruction: "Summarize this conversation overall, AND summarize what happened specifically on {date}"
4. Calls `sdk_query()` with `max_turns=1`, no tools, `permission_mode="bypassPermissions"`
5. Parses the response into two parts: session summary + today's activity
6. Persists the session summary to `session.summary` in the graph via `execute_cypher`
7. Returns today's activity summary to the parent agent

**Sub-agent system prompt:**
```
You are a conversation summarizer. Given a full chat transcript, produce:

1. SESSION SUMMARY: A 2-3 sentence overview of what this conversation is about
   overall — its purpose, key topics, and current state.

2. TODAY'S ACTIVITY ({date}): A focused summary of what specifically happened
   on this date. What was discussed, decided, built, or resolved? Be specific
   about outcomes and artifacts (PRs, files, decisions).

Messages from today are marked with [TODAY]. Earlier messages provide context.
```

**Scope requirement:** `frozenset({"date"})` — needs the target date to scope today's activity.

**SDK invocation pattern:**
```python
from claude_agent_sdk import ClaudeAgentOptions, query as sdk_query

opts = ClaudeAgentOptions(
    system_prompt=SUMMARIZER_SYSTEM_PROMPT,
    max_turns=1,
    permission_mode="bypassPermissions",
    model="claude-haiku",  # fast, cheap
)

async def prompt_gen():
    yield {"type": "user", "message": {"role": "user", "content": transcript_text}}

response = ""
async for event in sdk_query(prompt=prompt_gen(), options=opts):
    if hasattr(event, "content"):
        for block in event.content:
            if hasattr(block, "text"):
                response += block.text
```

**Edge cases:**
- Session with 0 messages on target date (only older messages) → skip, don't summarize
- Very long sessions (100+ exchanges) → truncate older messages, keep all of today's messages in full. Haiku has 200K context.
- Session already has a summary and no new messages → return cached summary, skip sub-agent call. Check by comparing `s.last_accessed` against a stored `s.summary_updated_at` field (add to schema).

### Phase 3: New `read_recent_cards` tool

**File:** `computer/parachute/core/daily_agent_tools.py`

New tool factory: `_make_read_recent_cards`. No required scope keys.

```python
@tool("read_recent_cards",
      "Read cards from recent days. Filter by card_type (e.g. 'reflection').",
      {"days": int, "card_type": str})
async def read_recent_cards(args):
    days = min(args.get("days", 7), 30)
    card_type = args.get("card_type", "")
    # Calculate date range
    # Query: MATCH (c:Card) WHERE c.date >= $start_date
    #        AND (card_type = '' OR c.card_type = $card_type)
    #        ORDER BY c.date DESC
```

### Phase 4: Update process-day template

**File:** `computer/parachute/db/brain_chat_store.py`

Update the `process-day` agent template:

1. **Tools:** `["read_days_notes", "read_days_chats", "summarize_chat", "read_recent_cards", "write_card"]`
   - Removed: `read_recent_journals` (redundant with `read_recent_cards` for reflection continuity)
   - Added: `summarize_chat`, `read_recent_cards`

2. **System prompt:** Updated to reflect the two-stage workflow:
   ```
   ## Process
   1. Read the day's chat sessions with `read_days_chats` — see what conversations happened
   2. For each substantive session, call `summarize_chat` to get a focused summary of what happened that day
   3. Read journal entries with `read_days_notes`
   4. Read recent reflection cards with `read_recent_cards` (type "reflection", last 7 days) for continuity
   5. Write your reflection using `write_card` with card_type "reflection"
   ```

3. **Bump `template_version`** to trigger re-seed on next startup.

### Phase 5: Schema update (minor)

**File:** `computer/parachute/db/brain_chat_store.py`

Add `summary_updated_at` column to Chat table for cache invalidation:
```python
"summary_updated_at": "STRING",  # ISO timestamp, set when summarize_chat persists a summary
```

## Acceptance Criteria

- [x] `read_days_chats` queries graph for sessions with messages on target date, returns lightweight list (no raw messages)
- [x] `summarize_chat` spawns Haiku sub-agent, reads full transcript, returns today's activity summary
- [x] `summarize_chat` persists full session summary to `session.summary` field
- [x] `summarize_chat` skips re-summarization when summary is fresh (no new messages)
- [x] `read_recent_cards` returns cards filtered by type and date range
- [x] Process-day template updated with new tools and system prompt
- [x] Reflection agent produces a `reflection` type card
- [x] Unit tests for new tools (mocked graph, mocked SDK)
- [x] `make test-fast` passes

## Technical Considerations

- **SDK nesting:** `summarize_chat` calls `sdk_query()` inside a tool that's running inside the parent agent's SDK session. This means a nested CLI process. The `CLAUDECODE` env var must be cleared (per MEMORY.md) to avoid "nested session" detection. Each sub-agent call is a fresh CLI process — no shared state.
- **Cost:** Each `summarize_chat` call is a Haiku invocation. On a busy day with 10 sessions, that's 10 Haiku calls. Cheap but not free. The caching (skip if summary is fresh) mitigates repeated runs.
- **Trust level:** The summarize sub-agent needs no tools — it only reads data passed in the prompt and returns text. Runs as direct with `max_turns=1`.
- **Message ordering:** Messages have `sequence` (INT64) and `created_at`. Use `sequence` for ordering within a session, `created_at` for date filtering.

## Dependencies & Risks

- **SDK subprocess from inside a tool:** This is the novel pattern. The parent SDK process holds stdin open via `done_event`. The child SDK process gets its own stdin/stdout. Should work but needs testing.
- **Haiku model availability:** The `model` option on `ClaudeAgentOptions` may need to be `claude-haiku` or `haiku` depending on SDK version. Verify at implementation time.
- **Graph write lock:** `summarize_chat` writes to `session.summary` while the parent agent's tool is running. The graph's `write_lock` handles this — no conflict since tools are sequential.

## Files to Modify

| File | Change |
|------|--------|
| `computer/parachute/core/daily_agent_tools.py` | Rewrite `read_days_chats`, add `summarize_chat`, add `read_recent_cards` |
| `computer/parachute/db/brain_chat_store.py` | Update process-day template (tools, prompt, version), add `summary_updated_at` column |
| `computer/tests/unit/test_daily_agent_tools.py` | Unit tests for new/rewritten tools |

## Out of Scope

- Dead code cleanup (activity hook, chat-log paths) — tracked in #352
- Multiple card types per day — future enhancement
- Brain entity integration — not in use yet
- User-customizable reflection prompts — ship good defaults first
- `read_recent_sessions` rewrite — removed from default tools; cleanup in #352
