# Unified Memory Search MCP

**Date:** 2026-03-08
**Status:** Brainstorm
**Priority:** P1
**Modules:** brain, computer
**Issue:** #203

---

## Context

With the migration to LadybugDB/Kuzu as core infrastructure, chat sessions, exchanges, and journal entries all live in the graph. But the MCP tools haven't caught up:

- `list_recent_sessions` and `search_sessions` crash with a file lock error (they try to open the DB file directly while the server already holds an exclusive lock)
- Journal tools (`list_recent_journals`, `get_journal`, `search_journals`) return empty — they still read from markdown files on disk; the data migrated into `Note` graph nodes but the tools didn't follow
- No tool searches Exchange content or Note content — only session titles
- The tool surface is fragmented: separate tools for journals, sessions, and brain queries force the agent to make multiple decisions and multiple calls

The data is there and healthy. The tool layer is broken and incomplete.

---

## What We're Building

A **unified `search_memory` tool** that treats all stored memory — chat sessions, conversation exchanges, and journal entries — as one searchable vault. Searches everything by default, with optional filters to narrow scope.

Alongside it, a consistent two-level retrieval pattern: search returns lightweight summaries and matched snippets, and the agent fetches full content only when it needs to go deeper.

All MCP tools route through the brain HTTP API proxy (never open the DB file directly), eliminating the file lock bug class entirely.

---

## Primary Use Cases

1. **Pre-conversation context surfacing** — Agent searches relevant history before diving in ("we talked about this a couple weeks ago" → finds the session + key exchanges)
2. **Mid-conversation memory retrieval** — User narrates a cue ("I journaled about this last week", "we've discussed this in chats"), agent picks up the signal and queries memory intelligently
3. **Date-scoped journal lookup** — "look at my journal entries from the last week" → filtered Note query with content returned

---

## Approach: Unified Tool, Graph-Native Search

### The `search_memory` tool

Single entry point. Searches across:
- `Chat.summary` — the bridge-generated session summaries (already rich and descriptive)
- `Exchange.description` + `Exchange.user_message` + `Exchange.ai_response` — conversation content
- `Note.content` + `Note.snippet` — journal and daily entries

**Parameters:**
- `query` (required) — keyword/phrase to search
- `source` (optional) — `"journal"`, `"chat"`, or omit for both
- `date_from` / `date_to` (optional) — ISO date strings, or relative hints like `"last_week"`
- `limit` (optional, default 10)

**Returns:** Ranked list of lightweight result objects:
```
{
  type: "session" | "journal",
  id: "<session_id or entry_id>",
  title: "...",
  date: "...",
  snippet: "...matched excerpt...",
  summary: "..."   // for sessions: bridge summary; for journals: full content if short
}
```

### Two-level retrieval

Search gives the agent enough to orient — title, date, summary, matched snippet. The agent decides whether to go deeper and calls `brain_get_session` or a new `get_note` tool to pull full content. This avoids dumping 20 exchanges when only one was relevant.

### Search implementation

Kuzu's native `CONTAINS` operator across the key fields. No new infrastructure — the data volume (hundreds of sessions, ~thousands of exchanges, ~hundreds of notes) is small enough that full-scan CONTAINS is plenty fast. FTS indexing and semantic/vector search can layer on later without changing the tool interface.

### Architecture fix

All tools — including the new `search_memory` — route through the brain HTTP API proxy (`http://localhost:3333/api/brain/`), the same pattern the working `brain_*` tools already use. Direct DB file access from MCP is removed. This eliminates the file lock conflict and makes the tool behavior consistent.

---

## Key Decisions

1. **One tool, not three** — Unified `search_memory` replaces the fragmented journal/session/brain search tools. Filters make it specific when needed.
2. **Route through API, never direct DB** — Fixes the lock bug and keeps a single write path.
3. **Two-level retrieval** — Search returns summaries + snippets. Full content fetched separately on demand.
4. **CONTAINS to start** — No FTS infrastructure needed now. Semantic search is a natural future layer on the same interface.
5. **Deprecate broken tools** — `list_recent_sessions`, `search_sessions`, `list_recent_journals`, `get_journal`, `search_journals` either get fixed to use the API or are superseded by the unified tool.

---

## What Gets Fixed Along the Way

- Journal tools read from `Note` graph nodes (not markdown files)
- Session list/search tools route through API (not direct DB)
- Search now covers content, not just titles

---

## Open Questions

- Should `search_memory` also search `Exchange` content by default, or only on explicit request? (Exchange content is verbose — could make results noisy)
- What's the right snippet length / context window around a match?
- Should relative date parsing ("last week") live in the tool or be left to the caller?
- Is `get_note` a new tool we need, or can `brain_query` cover that use case for now?

---

## Future Layers (Out of Scope Now)

- **FTS indexes** on Kuzu/DuckDB — better ranking, handles partial words, scales further
- **Vector/semantic search** — "find where I was thinking about identity and work" without exact keywords; needs embedding pipeline
- **Proactive memory injection** — agent surfaces relevant context automatically before conversations start, without being asked
