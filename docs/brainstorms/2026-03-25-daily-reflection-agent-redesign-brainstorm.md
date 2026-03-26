# Daily Reflection Agent Redesign

**Status:** Brainstorm
**Priority:** P2
**Labels:** daily, computer, enhancement
**Issue:** #351

## What We're Building

A two-stage daily reflection agent that summarizes your day across chats and journals, producing a single reflection card each night. The key insight: a sub-agent reads each chat's full transcript and produces a day-scoped summary, so the reflection agent itself works from clean, focused signal rather than raw messages.

## Why This Approach

The current daily reflection agent reads journal entries from the graph (works) but reads chat data from a dead filesystem path (`Daily/chat-log/`). Messages have moved to the graph, but even fixing that path wouldn't help much — dumping raw transcripts into the reflection agent's context is noisy and expensive. A two-stage approach keeps the reflection agent's context window clean while getting deep signal from each conversation.

## Architecture: Summarize → Reflect

### Stage 1: Gather and Summarize (sub-agents)

For each chat session active on the target date, the reflection agent calls `summarize_chat(session_id)`. Under the hood, a fast sub-agent (Haiku) reads the full session transcript and returns **two things**:

1. **Full session summary** — what is this conversation about overall. Gets persisted to the session's `summary` field in the graph (generate once, read many).
2. **Today's activity summary** — what specifically happened in this session *today*. This is what the reflection agent actually synthesizes from.

The distinction matters: a multi-day coding session needs context ("ongoing work on entry detail convergence") but the reflection cares about what happened *today* ("implemented EntryDetailScreen, ran review, merged PR"). The sub-agent reads the full transcript for context but scopes its output to today's messages.

If a session already has a summary and no new messages since it was generated, skip re-summarization.

### Stage 2: Reflect (main agent)

The reflection agent works from:

- **Lightweight session list** from `read_days_chats` — session IDs, titles, timestamps, message counts (no raw messages)
- **Per-session day summaries** from the `summarize_chat` calls
- **Journal entries** from `read_days_notes` (already works, queries the graph)
- **Last 7 days of reflection cards** from a new `read_recent_cards` tool — gives the agent continuity across days

It synthesizes everything into a single reflection card: what you were thinking about, working on, discussing, and how it connects to the broader arc of the week.

## Tool Changes

| Tool | Change | Details |
|------|--------|---------|
| `read_days_chats` | **Rewrite** | Query graph for sessions with activity on target date. Return lightweight list (id, title, message count, timestamps). No raw messages. |
| `summarize_chat` | **New** | Spawns sub-agent to read full transcript. Returns session context + today's activity. Persists full summary to session's `summary` field. |
| `read_recent_cards` | **New** | Query graph for cards by type and date range. Enables reading past reflection cards for week-over-week continuity. |
| `write_card` | **Update** | Ensure `card_type: "reflection"` works cleanly for type-based filtering. |
| `read_recent_sessions` | **Remove or rewrite** | Currently reads dead filesystem path. |

## Key Decisions

- **Sub-agent for chat summarization** — keeps reflection agent context clean, enables richer signal per conversation
- **Two-part summary output** — full session summary (persisted) + today's activity (used for reflection). Session summary is a side effect that revives dead `summary` field infrastructure.
- **Single reflection card per day** — start simple, may expand to multiple card types later
- **Last 7 days of reflection cards** as context — gives the agent continuity without unbounded history

## Open Questions

- What model for the summarizer sub-agent? Haiku is fast and cheap but may miss nuance in technical conversations.
- Should the reflection agent's system prompt be user-customizable from the start, or ship a good default and add customization later?
- How should `summarize_chat` handle very long sessions (100+ exchanges)? Chunked summarization or trust the model's context window?

## Cleanup (Separate Issue)

The following are dead code paths that should be cleaned up independently:

- `activity_hook.py` — writes to `Daily/.activity/` JSONL files that nothing reads
- `read_days_chats` / `read_recent_sessions` — read from `Daily/chat-log/` filesystem path that no longer exists
- Stale `session_summarizer.cpython-314.pyc` in `__pycache__` (source file deleted)
- Any remaining references to `Daily/chat-log/` directory throughout codebase
